import os
import sys
import time
import json
import asyncio
import functools
import subprocess
import warnings
import ssl
import logging
import re
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
from flask import Flask, request

# SSL 인증서 오류 해결
ssl._create_default_https_context = ssl._create_unverified_context

# 경고 메시지 숨기기
warnings.filterwarnings("ignore")

# --- 라이브러리 임포트 확인 ---
try:
    from google import genai
    from google.genai import types
    import firebase_admin
    from firebase_admin import credentials, storage, firestore
    from cryptography.fernet import Fernet
    import requests
except ImportError as e:
    sys.exit(f"필수 라이브러리 누락: {e}")

# --- 로깅 및 Flask 설정 ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# --- 1. 전역 설정 및 초기화 (가장 중요) ---

# [1] API Key 설정
api_key = os.environ.get("GOOGLE_API_KEY")
if not api_key:
    # .env 파일 로드 시도 (로컬 개발 편의용)
    try:
        from dotenv import load_dotenv
        load_dotenv()
        api_key = os.getenv("GOOGLE_API_KEY")
    except: pass

if not api_key:
    logger.error("FATAL ERROR: GOOGLE_API_KEY environment variable not found.")
else:
    try:
        client = genai.Client(api_key=api_key)
    except Exception as e:
        logger.error(f"FATAL ERROR: Failed to initialize Gemini client: {e}")

# [2] 암호화 키 설정
ENCRYPTION_KEY = os.environ.get("ENCRYPTION_KEY")
cipher = None
if ENCRYPTION_KEY:
    try:
        cipher = Fernet(ENCRYPTION_KEY)
        logger.info(f"🔒 Encryption Key Loaded ({ENCRYPTION_KEY[:4]}...)")
    except Exception as e:
        logger.warning(f"⚠️ ENCRYPTION_KEY init failed: {e}")
else:
    logger.warning("⚠️ ENCRYPTION_KEY not set. Data will be saved in plain text.")

# [3] Firebase 초기화 (하이브리드 방식)
# 로컬 테스트 시 사용할 키 파일 경로 *삭제 팔요함*
LOCAL_KEY_PATH = os.getenv("FIREBASE_CREDENTIALS_PATH")

if not firebase_admin._apps:
    try:
        if LOCAL_KEY_PATH and os.path.isfile(LOCAL_KEY_PATH):
            # 1. 로컬: 키 파일이 있으면 사용
            cred = credentials.Certificate(LOCAL_KEY_PATH)
            firebase_admin.initialize_app(cred)
            logger.info(f"✅ [Init] Firebase initialized with LOCAL Key: {os.path.basename(LOCAL_KEY_PATH)}")
        else:
            # 2. Cloud Run: 파일이 없으면 자동 인증(ADC) 사용
            firebase_admin.initialize_app()
            logger.info("✅ [Init] Firebase initialized with Cloud ADC")
    except Exception as e:
        logger.error(f"❌ [Fatal] Firebase Init Failed: {e}")
        # Firebase 없이는 작동 불가하므로 여기서 종료해도 됨
        sys.exit(1)

# [4] 스레드 풀
executor = ThreadPoolExecutor(max_workers=2)

# [5] Clova Speech API 설정 (화자분리 지원)
CLOVA_INVOKE_URL = os.environ.get("CLOVA_INVOKE_URL")
CLOVA_SECRET_KEY = os.environ.get("CLOVA_SECRET_KEY")

if CLOVA_INVOKE_URL and CLOVA_SECRET_KEY:
    logger.info("✅ [Init] Clova Speech API Ready")
else:
    logger.warning("⚠️ CLOVA_INVOKE_URL / CLOVA_SECRET_KEY 미설정 - 화자분리 불가")

# --- 2. 헬퍼 함수 ---

def extract_date_from_filename(filename):
    match = re.search(r'(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])', filename)
    if match: return f"{match.group(1)}-{match.group(2)}-{match.group(3)}"
    match = re.search(r'(20\d{2})[-_](0[1-9]|1[0-2])[-_](0[1-9]|[12]\d|3[01])', filename)
    if match: return f"{match.group(1)}-{match.group(2)}-{match.group(3)}"
    return None

def cleanup_local_file(file_path):
    if not file_path or not os.path.exists(file_path): return
    try:
        os.remove(file_path)
    except Exception:
        pass

def download_from_firebase(bucket_name, source_blob_name, destination_file_name):
    # 이미 전역에서 초기화되었으므로 바로 사용
    logger.info(f"🔥 [Download] Start: gs://{bucket_name}/{source_blob_name}")
    try:
        bucket = storage.bucket(bucket_name)
        blob = bucket.blob(source_blob_name)
        blob.download_to_filename(destination_file_name)
        logger.info(f"✅ [Download] Complete: {destination_file_name}")
        return destination_file_name
    except Exception as e:
        logger.error(f"⚠️ [Download] Failed: {e}")
        return None

def extract_audio_ffmpeg(video_path, audio_output_path):
    command = [
        "ffmpeg", "-i", video_path,
        "-vn", "-acodec", "libmp3lame", "-q:a", "4", "-y",
        audio_output_path
    ]
    try:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False

def analyze_audio_with_clova(file_path):
    """클로바 Speech API를 사용한 음성 인식 + 화자 분리"""
    if not CLOVA_INVOKE_URL or not CLOVA_SECRET_KEY:
        logger.warning("⚠️ Clova API 미설정 - STT 건너뛰")
        return ""

    audio_path = f"/tmp/temp_audio_{int(time.time())}.m4a"
    try:
        # 오디오 추출 (m4a 포맷 - 클로바 호환)
        command = [
            "ffmpeg", "-i", file_path,
            "-vn", "-acodec", "aac", "-b:a", "128k", "-y",
            audio_path
        ]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        if not os.path.exists(audio_path):
            logger.error("❌ 오디오 추출 실패")
            return ""

        # 클로바 API 호출
        with open(audio_path, 'rb') as f:
            audio_bytes = f.read()

        headers = {'X-CLOVASPEECH-API-KEY': CLOVA_SECRET_KEY}
        params = {
            'language': 'ko-KR',
            'completion': 'sync',
            'diarization': {
                'enable': True,
                'speakerCountMin': 1,
                'speakerCountMax': 6  # 영상에는 여러명이 나올 수 있음
            },
        }

        logger.info(f"🌐 [Clova STT] 전송: {len(audio_bytes)} bytes")

        response = requests.post(
            f"{CLOVA_INVOKE_URL}/recognizer/upload",
            headers=headers,
            files={
                'media': ('audio.m4a', audio_bytes),
                'params': (None, json.dumps(params), 'application/json')
            },
            timeout=180  # 영상이 길 수 있으므로 timeout 늘림
        )

        if response.status_code != 200:
            logger.error(f"❌ Clova API Error: {response.status_code} - {response.text[:500]}")
            return ""

        result_json = response.json()
        segments = result_json.get('segments', [])

        # 화자분리 결과 포맷팅
        formatted_result = []
        for seg in segments:
            speaker_info = seg.get('speaker', {})
            speaker = speaker_info.get('name', 'UNKNOWN') if isinstance(speaker_info, dict) else 'UNKNOWN'
            text = seg.get('text', '').strip()
            start_ms = seg.get('start', 0)  # 클로바는 ms 단위

            # ms -> MM:SS 변환
            start_sec = start_ms / 1000
            minutes = int(start_sec // 60)
            seconds = int(start_sec % 60)
            time_str = f"{minutes:02d}:{seconds:02d}"

            if text:  # 빈 텍스트 제외
                formatted_result.append({
                    "speaker": speaker,
                    "text": text,
                    "time": time_str
                })

        logger.info(f"✅ [Clova STT] 화자분리 완료: {len(formatted_result)}개 세그먼트")
        return json.dumps(formatted_result, ensure_ascii=False)

    except Exception as e:
        logger.error(f"⚠️ Clova STT Error: {e}")
        return ""
    finally:
        cleanup_local_file(audio_path)

def reencode_video(input_path):
    output_path = f"/tmp/opt_{os.path.basename(input_path)}"
    command = [
        "ffmpeg", "-i", input_path,
        "-vf", "scale='min(1920,iw)':-2", # FHD까지만 제한, 그 이하는 원본 유지
        "-c:v", "libx264", "-preset", "superfast", "-crf", "23",
        "-c:a", "aac", "-b:a", "128k", "-y", output_path
    ]
    try:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return output_path
    except Exception:
        return None

# --- 3. 비동기 분석 파이프라인 ---

async def async_upload_file(file_path):
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(executor, functools.partial(client.files.upload, file=file_path))
    except Exception as e:
        logger.error(f"Upload failed: {e}")
        return None

async def analyze_video_async(file_path, prompt, firebase_info=None):
    if not os.path.exists(file_path): return None

    file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
    upload_file_path = file_path
    compressed_path = None

    if file_size_mb > 500:
        logger.warning(f"⚠️ 500MB 초과 ({file_size_mb:.1f}MB). 최적화 중...")
        loop = asyncio.get_running_loop()
        compressed_path = await loop.run_in_executor(executor, reencode_video, file_path)
        if compressed_path and os.path.exists(compressed_path):
            upload_file_path = compressed_path

    # 2. Clova STT & Upload
    loop = asyncio.get_running_loop()
    upload_task = async_upload_file(upload_file_path)
    clova_task = loop.run_in_executor(executor, analyze_audio_with_clova, file_path)

    logger.info("🚀 Processing Pipeline Started...")
    uploaded_file, whisper_text = await asyncio.gather(upload_task, clova_task)

    if not uploaded_file: return None

    # 3. Polling
    while uploaded_file.state.name == "PROCESSING":
        await asyncio.sleep(2)
        uploaded_file = await loop.run_in_executor(executor, functools.partial(client.files.get, name=uploaded_file.name))

    if uploaded_file.state.name == "FAILED":
        logger.error("Gemini processing failed")
        return None

    # 4. 프롬프트 결합
    enhanced_prompt = f"{prompt}\n[Whisper Result]: {whisper_text[:2000]}"

    # 5. 스키마
    response_schema = {
        "type": "OBJECT",
        "properties": {
            "duration": {"type": "STRING"},
            "basic_info": {
                "type": "OBJECT",
                "properties": {
                    "category": {"type": "STRING"},
                    "location_inference": {"type": "STRING"},
                    "audio_atmosphere": {"type": "STRING"}
                }
            },
            "timeline_analysis": {
                "type": "ARRAY",
                "items": {"type": "OBJECT", "properties": {"time_range": {"type": "STRING"}, "action": {"type": "STRING"}}}
            },
            "summary": {
                "type": "OBJECT",
                "properties": {"caption": {"type": "STRING"}, "dominant_emotion": {"type": "STRING"}}
            },
            "ocr_analysis": {
                "type": "ARRAY",
                "items": {"type": "OBJECT", "properties": {"text": {"type": "STRING"}, "location": {"type": "STRING"}}}
            },
            "transcript": {
                "type": "ARRAY",
                "items": {"type": "OBJECT", "properties": {"speaker": {"type": "STRING"}, "text": {"type": "STRING"}, "time": {"type": "STRING"}}}
            },
            "appointments": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {"summary": {"type": "STRING"}}}},
            "keywords": {"type": "ARRAY", "items": {"type": "STRING"}}
        }
    }

    # 6. Gemini 요청
    final_data = None
    try:
        response = await loop.run_in_executor(
            executor,
            functools.partial(
                client.models.generate_content,
                model='gemini-2.5-pro',
                contents=[enhanced_prompt, uploaded_file],
                config=types.GenerateContentConfig(response_mime_type="application/json", response_schema=response_schema)
            )
        )

        if response and response.text:
            ai_result = json.loads(response.text)

            video_url = ""
            if firebase_info:
                bucket_name = firebase_info.get('bucket_name')
                blob_path = firebase_info.get('blob_path')
                safe_blob_path = blob_path.replace("/", "%2F")
                video_url = f"https://endpoint-2.example.invalid/v0/b/{bucket_name}/o/{safe_blob_path}?alt=media"

            final_data = {
                "media_type": "video",
                "file_id": os.path.basename(file_path),
                "timestamp": datetime.now().isoformat(),
                "video_url": video_url,
                **ai_result
            }
    except Exception as e:
        logger.error(f"Gemini Analysis Error: {e}")

    # Cleanup
    try:
        await loop.run_in_executor(executor, client.files.delete, uploaded_file.name)
    except: pass
    cleanup_local_file(compressed_path)

    return final_data

# --- 4. Firestore 저장 로직 ---

class CryptoManager:
    @staticmethod
    def encrypt_data(data) -> str:
        if data is None or cipher is None: return None
        try:
            text_data = data if isinstance(data, str) else json.dumps(data, ensure_ascii=False)
            return cipher.encrypt(text_data.encode('utf-8')).decode('utf-8')
        except Exception as e:
            logger.error(f"Encryption failed: {e}")
            return None

def save_to_firestore(data, blob_path):
    logger.info(f"🔥 [Firestore] Saving... ({blob_path})")
    try:
        db = firestore.client()
        user_id = "test_user"

        if blob_path:
            parts = blob_path.split('/')
            keywords = ['Users', 'users', 'videos']
            for kw in keywords:
                if kw in parts:
                    idx = parts.index(kw)
                    if idx + 1 < len(parts):
                        possible_uid = parts[idx + 1]
                        if possible_uid and not possible_uid.endswith('.mp4'):
                            user_id = possible_uid
                            break
            # 2차 시도
            if user_id == "test_user" and len(parts) >= 2:
                parent = parts[-2]
                if parent not in keywords: user_id = parent

        if user_id == "test_user":
            logger.warning("⚠️ User ID not found, using 'test_user'")

        extracted_date = extract_date_from_filename(data.get("file_id", ""))
        date_str = extracted_date if extracted_date else datetime.now().strftime("%Y-%m-%d")

        target_ref = db.collection("users").document(user_id).collection("daily_logs").document(date_str)

        # 암호화
        payload = data
        encrypted = CryptoManager.encrypt_data(data)
        if encrypted: payload = encrypted

        target_ref.set({
            "user_id": user_id,
            "date": date_str,
            "logs": firestore.ArrayUnion([payload]),
            "last_updated": firestore.SERVER_TIMESTAMP
        }, merge=True)

        logger.info(f"💾 Saved to Firestore: {user_id}/{date_str}")

    except Exception as e:
        logger.error(f"❌ Firestore Save Failed: {e}")

# --- 5. 서버 핸들러 (진입점) ---

@app.route('/', methods=['POST'])
def handle_event():
    event_data = request.get_json()
    if not event_data: return "No data", 400

    bucket_name = event_data.get('bucket')
    file_path = event_data.get('name')

    if not file_path or not bucket_name: return "Ignored", 200

    logger.info(f"🔔 파일 감지: gs://{bucket_name}/{file_path}")

    # 간단 필터링
    if not file_path.lower().endswith(('.mp4', '.avi', '.mov', '.mkv')):
        return "Not a video", 200

    local_path = f"/tmp/{os.path.basename(file_path)}"

    try:
        # 다운로드
        download_from_firebase(bucket_name, file_path, local_path)

        # 분석 프롬프트
        prompt = """
        이 영상은 치매 어르신이 자신의 시선으로 직접 촬영한 기록입니다.
        다음 가이드에 따라 제공된 JSON 스키마 형식으로 분석 결과를 생성해 주세요.

        1. basic_info (기본 정보):
        - category: 영상의 주된 성격 (예: 기억 기록, 길 찾기 시도, 사물 확인, 혼란 상태 기록 등)
        - location_inference: 화면 속 배경을 바탕으로 한 장소 추론 (예: 거실, 주방, 낯선 길거리, 병원, 방 등)
        - audio_atmosphere: 어르신의 숨소리, 혼잣말, 주변 소리에서 느껴지는 전반적인 분위기

        2. timeline_analysis (타임라인 분석):
        - 어르신의 카메라 움직임과 시선의 변화를 시간대별 동적 행동으로 기록하세요.
        - 예: "카메라를 흔들며 바닥을 반복해서 비춤(무언가 찾는 행동)", "가족 사진을 10초간 고정하여 응시함"

        3. summary (요약):
        - caption: 어르신이 이 영상을 촬영한 핵심 목적이나 당시 상황에 대한 한 문장 요약
        - dominant_emotion: 촬영 중 느껴지는 어르신의 주된 감정 (예: 호기심, 불안, 성취감, 그리움)

        4. ocr_analysis (시각적 텍스트):
        - 어르신이 중요하게 비춘 글자(약봉지의 글씨, 달력의 메모, 이정표 등)를 추출하세요.

        5. transcript & appointments (음성 및 약속):
        - transcript: 촬영 중 어르신의 혼잣말이나 타인과의 대화를 시간대별로 기록하세요.
            - **반드시 화자(speaker) 정보를 포함하세요** (예: SPEAKER_00, SPEAKER_01 등)
            - Whisper Result에 화자 정보가 있으면 그대로 사용하고, 없으면 영상 분석을 통해 추론하세요.
            - 대화를 정확하게 인식하기 어려운 경우, 추정되는 내용을 최대한 기술하세요.
            - 대화는 요약 하지 말고 가능한 상세히 기록하세요.
        - appointments: 대화나 화면(메모 등)에서 유추되는 향후 일정이나 해야 할 일(예: "3시에 약 먹기")을 추출하세요.

        6. keywords (핵심 키워드):
        - 어르신의 상태와 관심사를 나타내는 핵심 해시태그 (예: 가족사진, 기억의지, 반복촬영, 길찾기, 평온한오후)
"""

        # 분석 실행
        result = asyncio.run(analyze_video_async(local_path, prompt, {'bucket_name': bucket_name, 'blob_path': file_path}))

        if result:
            save_to_firestore(result, file_path)
            return "Success", 200
        else:
            return "Analysis Failed", 500

    except Exception as e:
        logger.error(f"❌ Critical Error in handle_event: {e}")
        return f"Error: {e}", 500
    finally:
        cleanup_local_file(local_path)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
