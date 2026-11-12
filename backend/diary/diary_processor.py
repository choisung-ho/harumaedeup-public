import os
import re
import json
import base64
import requests
import google.auth
import google.auth.transport.requests
import firebase_admin
from firebase_admin import firestore, storage
from google.cloud import firestore_v1
import vertexai
# [삭제됨] 사용하지 않는 TextEmbeddingModel 임포트 제거
from vertexai.generative_models import GenerativeModel, GenerationConfig
# [보안] 암호화 모듈
from utils.crypto_utils import CryptoManager

# 설정
PROJECT_ID = os.environ.get("GCLOUD_PROJECT")
LOCATION = "us-central1"
STORAGE_BUCKET_NAME = os.getenv("STORAGE_BUCKET_NAME")

# 모델 설정
# [삭제됨] EMBED_MODEL_NAME 제거
DRAFT_MODEL_NAME = "gemini-2.5-flash"
POLISH_MODEL_NAME = "gemini-2.5-pro"

# ★ [스타일 고정] Memory Care 프롬프트
MEMORY_CARE_PROMPT = (
    "Polish the diary to be senior-friendly while strictly maintaining the chronological time markers.\n"
    "- **Rule 1**: Use headers '🌟 오늘의 소중한 기억' and '🕒 오늘 하신 일들'.\n"
    "- **Rule 2**: Each entry in the timeline MUST start with the specific time, e.g., '[오전 10시 00분]'.\n"
    "- **Rule 3**: STRICTLY NO ENGLISH allowed in the output text.\n"
    "- **Rule 4**: Use gentle Korean honorifics ('~하셨어요', '~네요') to provide emotional comfort."
)

# -----------------------------------------------------------------------------
# [Init] Vertex AI 초기화
# -----------------------------------------------------------------------------
def init_vertex_ai():
    try:
        vertexai.init(project=PROJECT_ID, location=LOCATION)
    except Exception as e:
        print(f"⚠️ Vertex AI Init Error: {e}")

# -----------------------------------------------------------------------------
# [Helper] TTS 생성 및 업로드 (Cloud Functions용 인증 적용)
# -----------------------------------------------------------------------------
def generate_tts_and_upload(user_id: str, date: str, raw_ssml_text: str, bucket):
    if not raw_ssml_text: return None, []

    # 1. SSML 성형
    clean_ssml = raw_ssml_text.replace("<speak>", "").replace("</speak>", "").strip()
    clean_ssml = re.sub(r'<mark\s+name=["\'](.*?)["\']\s*/?>', r'<mark name="\1"/>', clean_ssml)
    final_ssml = f"<speak>{clean_ssml}</speak>".replace("'", '"')

    print(f"🎤 [TTS] 생성 시작 (길이: {len(final_ssml)})")

    final_time_offsets = []
    public_url = ""

    try:
        # [Cloud Functions 인증] 로컬 키 파일 대신 기본 인증 사용
        credentials, project = google.auth.default(scopes=['https://www.googleapis.com/auth/cloud-platform'])
        auth_req = google.auth.transport.requests.Request()
        credentials.refresh(auth_req)
        token = credentials.token

        url = "https://texttospeech.googleapis.com/v1beta1/text:synthesize"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8"
        }
        data = {
            "input": {"ssml": final_ssml},
            "voice": {
                "languageCode": "ko-KR",
                # Neural2-A (여성), Neural2-C (남성) 중 선택
                "name": "ko-KR-Neural2-A"
            },
            "audioConfig": {
                "audioEncoding": "MP3",
                "speakingRate": 0.85,  # <--- [추가] 속도를 0.85배로 (약 15% 느리게)
                "pitch": 0.0           # (선택) 필요하면 톤도 조절 가능
            },
            "enableTimePointing": ["SSML_MARK"]
        }

        response = requests.post(url, headers=headers, json=data)
        result = response.json()

        if response.status_code == 200 and "audioContent" in result:
            # Storage 업로드
            audio_content = base64.b64decode(result["audioContent"])
            file_path = f"Users/{user_id}/result/tts_audio/{date}.mp3"
            blob = bucket.blob(file_path)
            blob.upload_from_string(audio_content, content_type="audio/mpeg")

            # 공개 URL 생성 (권한 설정 필요할 수 있음, 실패 시 signed url 고려)
            try:
                blob.make_public()
                public_url = blob.public_url
            except:
                # 공개 실패 시 Signed URL (1년 유효) 생성 시도 또는 비공개 유지
                public_url = blob.generate_signed_url(expiration=31536000, method='GET')

            # 마크 포인트 추출
            raw_points = result.get("timePoints") or result.get("timepoints") or result.get("time_points") or []
            for tp in raw_points:
                sec = tp.get("timeSeconds") or tp.get("timeseconds") or 0
                final_time_offsets.append({
                    "mark_name": tp.get("markName") or tp.get("markname"),
                    "time_seconds": float(sec)
                })
            print(f"🔥 [TTS 성공] URL 생성 완료 ({len(final_time_offsets)} marks)")
        else:
             print(f"❌ [TTS API 오류] {result}")

    except Exception as e:
        print(f"❌ [TTS 처리 실패] {e}")

    # [Fallback] API 마크 실패 시 계산 로직 (Plan B)
    if not final_time_offsets and public_url:
        print("⚠️ [TTS Plan B] 텍스트 길이 비례 계산 시작")
        temp_text = clean_ssml
        mark_positions = []
        for m in re.finditer(r'<mark name="(.*?)"/>', temp_text):
            mark_positions.append((m.group(1), len(re.sub(r'<[^>]+>', '', temp_text[:m.start()]))))

        full_clean_text = re.sub(r'<[^>]+>', '', temp_text)
        total_len = max(len(full_clean_text), 1)
        # estimated_duration = total_len / 3.2 # 대략적인 한국어 발화 속도
        current_speaking_rate = 0.85
        base_speed = 3.2 # 1.0 배속일 때 초당 글자 수

        # 속도가 느려지면(0.85), 초당 읽는 글자 수는 줄어듭니다 (3.2 * 0.85)
        real_speed = base_speed * current_speaking_rate
        estimated_duration = total_len / real_speed

        for name, char_idx in mark_positions:
            calc_time = (char_idx / total_len) * estimated_duration
            final_time_offsets.append({
                "mark_name": name,
                "time_seconds": round(calc_time, 1)
            })

    return public_url, final_time_offsets

# -----------------------------------------------------------------------------
# [Helper] 사용자 정보 조회
# -----------------------------------------------------------------------------
# [삭제됨] clean_log_for_embedding 함수 제거

def get_user_name(db, user_id: str) -> str:
    try:
        doc = db.collection("users").document(user_id).get()
        if doc.exists:
            return doc.to_dict().get("name", "어르신")
    except: pass
    return "어르신"

# -----------------------------------------------------------------------------
# [Helper] 로그 포맷팅
# -----------------------------------------------------------------------------
def format_db_logs_to_string(user_id, date, logs):
    valid_logs = [x for x in logs if x and isinstance(x, dict)]
    valid_logs.sort(key=lambda x: x.get("timestamp", "9999"))

    text = f"User: {user_id}\nDate: {date}\n\n[Activity Log]\n"

    for log in valid_logs:
        etype = log.get('media_type') or log.get('type', 'unknown')
        ts = log.get('timestamp', '')
        time_str = "00:00" # 기본값

        try:
            # Case 1: "2025-12-25T09:40:00" (ISO 포맷)
            if "T" in ts:
                time_str = ts.split("T")[1][:5]
            # Case 2: "2025-12-25 09:40:00" (일반 DB 포맷, test_call_1.json)
            elif " " in ts:
                time_str = ts.split(" ")[1][:5]
            # Case 3: 시간이 없는 경우 등
            else:
                pass
        except:
            time_str = "00:00"

        if etype == 'call':
            partner = log.get('partner', '알 수 없음')
            content = log.get('content', '내용 없음')
            text += f"- [{time_str}] 📞 통화 ({partner}): {content}\n"

            # [수정됨] Highlight 오디오 추출 (call_audio_url)
            highlight = log.get('highlight') or {}
            h_url = highlight.get('call_audio_url') # 필드명 변경됨
            h_text = highlight.get('text', '')

            if h_url:
                text += f"    >> [Audio_1:Highlight] URL: {h_url} | 하이라이트: {h_text}\n"

            # [수정됨] Calendar 오디오 추출 (calendar_audio_url)
            cal_event = log.get('calendar_event') or {}
            c_url = cal_event.get('calendar_audio_url') # 필드명 변경됨
            c_content = cal_event.get('content', '')
            c_loc = cal_event.get('location', '')

            if c_url:
                text += f"    >> [Audio_2:Schedule] URL: {c_url} | 일정내용: {c_content} (장소: {c_loc})\n"
        elif etype == 'sms':
            sender = log.get('sender_phone') or log.get('partner', '알 수 없음')
            content = log.get('message_body') or log.get('content', '내용 없음')
            text += f"- [{time_str}] 📩 문자 ({sender}): {content}\n"

        elif etype == 'location':
            text += f"- [{time_str}] 📍 위치: {log.get('place_name', log.get('address'))}\n"

        elif etype == 'image':
            # 1. 기존 상세 정보 파싱
            detail = log.get('how_detail') or {}
            if isinstance(detail, str):
                try: detail = json.loads(detail)
                except: detail = {}

            what_info = detail.get('what') or log.get('what', '알 수 없음')
            where_info = detail.get('where') or log.get('where', log.get('where_place', '장소 불명'))
            how_info = detail.get('how') or log.get('how', log.get('how_mood', []))
            why_info = detail.get('why') or log.get('why', log.get('why_purpose', ''))

            # -------------------------------------------------------
            # [추가됨] names 필드 추출 및 포맷팅
            # -------------------------------------------------------
            detected_names = log.get('names', [])
            people_context = ""
            if detected_names:
                # 리스트를 문자열로 변환 (예: "김차겸, 둘째 아들 윤여민")
                people_context = ", ".join(detected_names)

            text += f"- [{time_str}] 📸 사진 촬영 ({what_info})\n"

            # 인물 정보가 있을 경우에만 라인 추가
            if people_context:
                text += f"    * 등장인물: {people_context}\n"

            text += f"    * 내용: {detail}\n"
            text += f"    * URL: {log.get('image_url', log.get('url', 'URL 없음'))}\n"
            text += f"    * 장소: {where_info}\n"
            text += f"    * 분위기: {how_info} | 목적: {why_info}\n"

        elif etype == 'video':
            # 1. 기본 정보 파싱
            basic = log.get('basic_info') or {}
            summary = log.get('summary') or {}

            v_category = basic.get('category', '동영상')
            v_location = basic.get('location_inference', '장소 불명') # [NEW] 장소 추론
            v_atmosphere = basic.get('audio_atmosphere', '')

            v_caption = summary.get('caption', '설명 없음')
            v_emotion = summary.get('dominant_emotion', '') # [NEW] 감정

            # 2. 타임라인 행동 분석 (가장 중요한 서사 데이터) [NEW]
            timeline = log.get('timeline_analysis') or []
            timeline_txt = ""
            if timeline:
                timeline_txt = "    * [상세 행동 흐름]:\n"
                for item in timeline:
                    # 예: "- 00:00-00:30: 부엌에서 요리 (요리 준비 중)"
                    t_range = item.get('time_range', '')
                    t_action = item.get('action', '')
                    t_summary = item.get('transcript_summary', '')
                    timeline_txt += f"      - ({t_range}) {t_action}: {t_summary}\n"

            # 3. 대화 내용 (Transcript)
            transcripts = log.get('transcript') or []
            dialogue_txt = ""
            if transcripts:
                # 대화가 너무 길면 앞부분 5줄만 발췌해서 문맥 제공
                dialogue_lines = [f"\"{t.get('text')}\"" for t in transcripts[:5]]
                dialogue_joined = ", ".join(dialogue_lines)
                dialogue_txt = f"    * [대화 엿보기]: {dialogue_joined} ...\n"

            # 4. AI에게 넘겨줄 최종 텍스트 조립
            text += f"- [{time_str}] 📹 동영상 촬영 ({v_category}) @ {v_location}\n"
            text += f"    * 내용: {v_caption}\n"

            # 감정과 분위기가 있으면 추가
            mood_info = []
            if v_emotion: mood_info.append(f"감정: {v_emotion}")
            if v_atmosphere: mood_info.append(f"분위기: {v_atmosphere}")
            if mood_info:
                text += f"    * 분위기/감정: {', '.join(mood_info)}\n"

            text += f"    * URL: {log.get('video_url', log.get('url', 'URL 없음'))}\n"

            # 상세 분석 내용 붙이기
            text += timeline_txt
            text += dialogue_txt

            if 'keywords' in log:
                text += f"    * 키워드: {', '.join(log.get('keywords', []))}\n"

    return text

# -----------------------------------------------------------------------------
# [Logic] 메인 일기 생성 함수
# -----------------------------------------------------------------------------
def process_diary_generation(user_id, date_str):
    print(f"🚀 [Diary Logic] 일기 생성 시작: {user_id} / {date_str}")

    if not firebase_admin._apps:
        firebase_admin.initialize_app()

    db = firestore.client()
    bucket = storage.bucket(STORAGE_BUCKET_NAME)
    init_vertex_ai()

    # 1. DB에서 로그 가져오기
    doc_ref = db.collection("users").document(user_id).collection("daily_logs").document(date_str)
    doc = doc_ref.get()

    if not doc.exists:
        print("⚠️ 해당 날짜 로그 없음. 종료.")
        return

    data = doc.to_dict()
    encrypted_logs = data.get("logs", [])
    encrypted_locs = data.get("location_logs", [])

    all_logs = []
    # 복호화 통합
    # [수정] 복호화 통합 및 데이터 구조 평탄화 (Flattening)
    for enc in encrypted_logs + encrypted_locs:
        try:
            dec = CryptoManager.decrypt_data(enc)
            if not dec: continue

            # Case 1: 리스트 형태 ([...]) -> 전화, 문자 등 (test_call_1.json 대응)
            if isinstance(dec, list):
                all_logs.extend(dec)

            # Case 2: 이중 포장된 딕셔너리 ({'logs': [...]}) -> 풀어서 넣기
            elif isinstance(dec, dict) and 'logs' in dec and isinstance(dec['logs'], list):
                all_logs.extend(dec['logs'])

            # Case 3: 단일 객체 ({...}) -> 비디오, 이미지 등
            elif isinstance(dec, dict):
                all_logs.append(dec)

        except Exception as e:
            print(f"⚠️ 로그 처리 중 에러(건너뜀): {e}")
            continue

    # ------------------------------------------------------------------
    # [🚨 핵심 안전장치] 리스트 안에 섞인 None, 빈 값, 딕셔너리가 아닌 것 완벽 제거
    # 이 코드가 있어야 'NoneType' object has no attribute 'get' 에러가 100% 사라집니다.
    # ------------------------------------------------------------------
    all_logs = [log for log in all_logs if log and isinstance(log, dict)]

    if not all_logs:
        print("⚠️ 유효한 로그가 없습니다. 종료.")
        return

    print(f"   📚 총 {len(all_logs)}개의 로그 확보.")
    current_log_text = format_db_logs_to_string(user_id, date_str, all_logs)
    user_name = get_user_name(db, user_id)

    # 2. AI 생성 (Gemini)
    SYSTEM_INSTRUCTION = (
    f"You are 'Haru Maedeup' (하루매듭), a warm Memory Care AI. User Name: {user_name}."
    "Your mission is to analyze logs and create a JSON response that helps seniors recall their day.\n\n"

    "### [Output Schema (JSON)]\n"
    "Respond with a JSON object containing exactly these five keys:\n"
    "1. \"diary\": A structured summary for reading (Use headers '🌟 오늘의 소중한 기억', '🕒 오늘 하신 일들').\n"
    "2. \"storytelling_script\": A warm, 1-minute radio-style script for TTS. Must include SSML marks (<mark name='cue_X'/>).\n"
    "3. \"keywords\": 3-5 Korean tags (e.g., [\"손주 방문\", \"전복죽\"]).\n"
    "4. \"events\": A list of future tasks objects. Schema: [{\"date\": \"YYYY-MM-DD\", \"title\": \"Event Name\"}]. Return [] if none.\n"
    "5. \"cue_sheet\": A list of objects to sync visuals. Schema: [{\"time_seconds\": 0, \"type\": \"greeting|call|sms|location|image|video|closing\", \"resource_url\": \"URL or null\", \"caption\": \"text\"}].\n\n"

    "### [CRITICAL: Synchronization Rules] (Must Follow)\n"
    "1. **One Mark = One Scene**: The number of `<mark name='cue_X'/>` tags in the script MUST EXACTLY MATCH the number of items in the `cue_sheet` list.\n"
    "2. **Mark Positioning**: \n"
    "   - **ALWAYS** place the `<mark name='cue_X'/>` tag **IMMEDIATELY BEFORE** the sentence it corresponds to.\n"
    "   - **Bad**: '안녕하세요.<mark name='cue_0'/>' (Do NOT do this)\n"
    "   - **Good**: '<mark name='cue_0'/>안녕하세요.' (Do this)\n"
    "3. **Mandatory Events** (Strict Order):\n"
    "   - **Start**: Start the very first sentence with `<mark name='cue_0'/>` (type: `greeting`).\n"
    "   - **Body**: Insert marks BEFORE mentioning:\n"
    "     1) **Movement/Place** (type: `location`)\n"
    "     2) **Phone Call** (type: `call`)\n"
    "     3) **SMS/Message** (type: `sms`)\n"
    "     4) **Visuals** (type: `image`/`video`)\n"
    "   - **End**: Insert a mark BEFORE the final farewell sentence (type: `closing`).\n"
    "4. **Resource Handling**:\n"
    "   - `image`/`video`: Must use a valid `resource_url` from logs.\n"
    "   - `call`: If the log has an audio URL, Use that URL. Otherwise, set to `null`.\n"
    "   - `greeting`/`sms`/`location`/`closing`: Set `resource_url` to `null`.\n\n"

    "### [Special Logic: Dual Audio Calls] (Override Rule)\n"
        "If a single call log contains BOTH `[Audio_1:Highlight]` and `[Audio_2:Schedule]`, you MUST split the narrative into two distinct scenes:\n"
        "1. **Scene A (Emotion)**: Talk about the conversation's mood. -> Insert `<mark name='cue_A'/>` -> Use `Audio_1` URL for this item in cue_sheet.\n"
        "2. **Scene B (Plan)**: Mention the scheduled event or promise. -> Insert `<mark name='cue_B'/>` -> Use `Audio_2` URL for this item in cue_sheet.\n"
        "   - *Note*: Ideally, Scene B should follow Scene A immediately.\n\n"

    "### [Storytelling Script Rules]\n"
    "- **Persona**: You are 'Haru Maedeup' (하루매듭). Speak with the affection of a grandchild but introduce yourself as 'Haru Maedeup'.\n"
    "- **Structure**: \n"
    f"  - **Opening**: `<mark name='cue_0'/>` + Greeting (MUST include: '{user_name} 어르신, 안녕하세요! 하루매듭입니다.').\n"
    "  - **Body**: Connect events naturally.\n"
    "  - **Closing**: `<mark name='cue_N'/>` + Final message.\n"
    "- **SSML Wrapping**: Wrap the entire script in `<speak>` tags.\n\n"

    "### [Cue Sheet Rules]\n"
    "- **Caption**: \n"
    "  - `location`: '000로 이동' or Place Name (e.g., '노인복지관').\n"
    "  - `call`: '000님과의 목소리' (If audio exists) or '000님과 통화'.\n"
    "  - `sms`: '000님의 문자' or '000님에게 온 소식'.\n"
    "  - `greeting`: '하루매듭의 아침 인사'.\n"
    "- **Prioritize Video**: If an event has both image and video, use 'video'.\n"
    "- **Fake URL Forbidden**: Do not invent URLs.\n\n"

    "### [Timeline Rules]\n"
    "- In the '🕒 오늘 하신 일들' section, ALWAYS use the format: '[오전/오후 HH시 MM분] - 내용'."
)

    try:
        # Step 1: Draft
        model = GenerativeModel(DRAFT_MODEL_NAME)
        prompt = f"System: {SYSTEM_INSTRUCTION}\n\n[Today's Logs]\n{current_log_text}\n\nGenerate JSON response."

        response = model.generate_content(
            prompt,
            generation_config=GenerationConfig(response_mime_type="application/json", temperature=0.7)
        )
        draft_json = json.loads(response.text)

        # Step 2: Polish (Memory Care Style)
        polish_model = GenerativeModel(POLISH_MODEL_NAME)
        polish_prompt = f"{MEMORY_CARE_PROMPT}\n\n[Content]\n{draft_json.get('diary','')}"
        polish_res = polish_model.generate_content(polish_prompt)
        final_diary = polish_res.text

        # 3. TTS 생성 및 업로드 (복원됨)
        story_ssml = draft_json.get("storytelling_script", "")
        tts_url, real_time_points = generate_tts_and_upload(user_id, date_str, story_ssml, bucket)

        # 4. 큐시트 싱크 맞추기
        cue_sheet = draft_json.get("cue_sheet", [])
        if tts_url and real_time_points:
            min_len = min(len(real_time_points), len(cue_sheet))
            for i in range(min_len):
                cue_sheet[i]['time_seconds'] = int(real_time_points[i]['time_seconds'])

        # 5. 결과 암호화 및 저장
        save_data = {
            "user_id": user_id,
            "name": user_name,
            "timestamp": date_str,
            "content": CryptoManager.encrypt_data(final_diary),
            "story_script": CryptoManager.encrypt_data(story_ssml),
            "keywords": CryptoManager.encrypt_data(draft_json.get("keywords")),
            "context_summary": CryptoManager.encrypt_data(current_log_text),
            "cue_sheet": CryptoManager.encrypt_data(cue_sheet), # 구조체 유지
            "tts_url": CryptoManager.encrypt_data(tts_url), # URL 암호화
            "created_at": firestore.SERVER_TIMESTAMP
        }

        # [수정 후] "삭제 후 저장" 방식으로 변경 (적재 방지)
        target_ref = db.collection("users").document(user_id).collection("diary").document(date_str)

        # 1. 기존 일기가 있다면 확실하게 삭제 (Clean Slate)
        #    이렇게 하면 이전 분석 결과가 남거나 섞일 일이 100% 없습니다.
        try:
            target_ref.delete()
            print(f"   🧹 [초기화] 기존 일기 문서 삭제 완료: {date_str}")
        except Exception as e:
            print(f"   ⚠️ 삭제 중 경고(무시 가능): {e}")

        # 2. 깨끗한 상태에서 새로 저장
        target_ref.set(save_data)

        print(f"✅ [일기 및 TTS 저장 완료] {date_str}")

    except Exception as e:
        print(f"❌ 일기 생성 중 에러: {e}")
