import os
import json
import shutil
import asyncio
import re
import tempfile
import aiohttp
import requests
from datetime import datetime
from typing import List, Dict, Optional
from contextlib import asynccontextmanager
import unicodedata
import hashlib

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, BackgroundTasks
from pydantic import BaseModel
from dotenv import load_dotenv

import firebase_admin
from firebase_admin import credentials, storage, firestore, messaging
from google.cloud import firestore as gc_firestore  # 트랜잭션용

# AI & Audio Libs
from google import genai
from google.genai import types
import vertexai
from vertexai.generative_models import GenerativeModel, GenerationConfig

# transformers, speechbrain 등 무거운 라이브러리는 함수 내부에서 import (Lazy Loading)
from cryptography.fernet import Fernet

# ★ 경로 설정
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(BASE_DIR)

# --- [1. 전역 설정 및 환경 변수] ---
env_path_local = os.path.join(BASE_DIR, ".env")
env_path_root = os.path.join(ROOT_DIR, ".env")

if os.path.exists(env_path_local):
    load_dotenv(env_path_local, override=True)
elif os.path.exists(env_path_root):
    load_dotenv(env_path_root, override=True)
else:
    load_dotenv()

CREDENTIALS_PATH = os.getenv("FIREBASE_CREDENTIALS_PATH") or os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
if not CREDENTIALS_PATH or not os.path.exists(CREDENTIALS_PATH):
    possible_paths = [
        os.path.join(BASE_DIR, "serviceAccountKey.json"),
        "/app/serviceAccountKey.json" # Docker path
    ]
    for p in possible_paths:
        if os.path.exists(p):
            CREDENTIALS_PATH = p
            break

# ★ API 키 및 설정
CLOVA_INVOKE_URL = os.getenv("CLOVA_INVOKE_URL")
CLOVA_SECRET_KEY = os.getenv("CLOVA_SECRET_KEY")
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
PROJECT_ID = os.getenv("PROJECT_ID")
STORAGE_BUCKET_NAME = os.getenv("STORAGE_BUCKET_NAME")
ENCRYPTION_KEY = os.getenv("ENCRYPTION_KEY")

if ENCRYPTION_KEY:
    try:
        cipher = Fernet(ENCRYPTION_KEY.encode())
    except Exception as e:
        print(f"❌ Cipher Init Failed: {e}")
        cipher = None
else:
    cipher = None

# Windows Symlink 오류 방지
os.environ["HF_HUB_DISABLE_SYMLINKS"] = os.getenv("HF_HUB_DISABLE_SYMLINKS", "1")
if CREDENTIALS_PATH:
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = CREDENTIALS_PATH

# ★ [Cloud Run 호환] /tmp 캐시 경로 설정 (읽기 전용 파일 시스템 우회)
# Cloud Run은 /tmp만 쓰기 가능하므로 모든 캐시를 /tmp로 지정
TMP_CACHE_DIR = "/tmp/model_cache"
os.makedirs(TMP_CACHE_DIR, exist_ok=True)
os.environ["HF_HOME"] = os.path.join(TMP_CACHE_DIR, "huggingface")
os.environ["TRANSFORMERS_CACHE"] = os.path.join(TMP_CACHE_DIR, "transformers")
os.environ["TORCH_HOME"] = os.path.join(TMP_CACHE_DIR, "torch")
os.environ["XDG_CACHE_HOME"] = TMP_CACHE_DIR

# --- [2. 클라이언트 초기화] ---

# Firebase
db = None
bucket = None
if not firebase_admin._apps and CREDENTIALS_PATH:
    try:
        cred = credentials.Certificate(CREDENTIALS_PATH)
        firebase_admin.initialize_app(cred, {'storageBucket': STORAGE_BUCKET_NAME})
        db = firestore.client()
        bucket = storage.bucket()
        print("✅ Firebase 초기화 완료")
    except Exception as e:
        print(f"Firebase 초기화 실패: {e}")

# Google AI Clients
genai_client = None
if GOOGLE_API_KEY:
    try:
        genai_client = genai.Client(api_key=GOOGLE_API_KEY)
    except Exception as e:
        print(f"Google AI 초기화 실패: {e}")

try:
    vertexai.init(project=PROJECT_ID, location="us-central1")
except Exception as e:
    print(f"Vertex AI 초기화 실패: {e}")


# ★ [Lazy Loading] 전역 모델 저장소
# 서버 시작 시에는 None 상태이며, 실제 요청 시 로드됩니다.
global_models = {
    "voice_auth": None,
    "keybert": None
}

# --- [Helper Functions] ---

def get_user_real_name(user_id: str) -> str:
    """Firestore에서 사용자의 실제 이름을 가져옵니다."""
    if not db:
        return "나" # DB 연결 안됨
    try:
        # users 컬렉션의 해당 user_id 문서 조회
        doc_ref = db.collection("users").document(user_id)
        doc = doc_ref.get()

        if doc.exists:
            data = doc.to_dict()
            # 'name' 필드를 우선 찾고, 없으면 'username', 그것도 없으면 "나" 반환
            return data.get("name") or data.get("username") or "나"
        else:
            print(f"사용자({user_id}) 문서를 찾을 수 없습니다.")
            return "나"
    except Exception as e:
        print(f"사용자 이름 조회 실패: {e}")
        return "나"

class CryptoManager:
    @staticmethod
    def encrypt_data(data) -> str:
        if data is None or cipher is None: return None
        try:
            if not isinstance(data, str): text_data = json.dumps(data, ensure_ascii=False)
            else: text_data = data
            return cipher.encrypt(text_data.encode('utf-8')).decode('utf-8')
        except Exception: return None

def extract_uid_from_path(blob_path: str) -> Optional[str]:
    if not blob_path: return None
    parts = blob_path.split('/')
    for kw in ['Users', 'users', 'videos', 'user_voices', 'source']:
        if kw in parts:
            kw_idx = parts.index(kw)
            if kw_idx + 1 < len(parts) and parts[kw_idx + 1]: return parts[kw_idx + 1]
    if len(parts) >= 2 and parts[-2] not in ["Users", "voice", "calls"]: return parts[-2]
    return "test_user"

def extract_date_from_filename(filename: str) -> Optional[str]:
    match = re.search(r'(20\d{2})[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12]\d|3[01])', filename)
    if match: return f"{match.group(1)}-{match.group(2)}-{match.group(3)}"
    return None

def extract_datetime_from_filename(filename: str) -> Optional[str]:
    match = re.search(r'(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[-_]?(\d{2})(\d{2})(\d{2})?', filename)
    if match:
        return f"{match.group(1)}-{match.group(2)}-{match.group(3)} {match.group(4)}:{match.group(5)}:{match.group(6) or '00'}"
    date_only = extract_date_from_filename(filename)
    if date_only: return f"{date_only} 00:00:00"
    return None

class StorageAnalysisRequest(BaseModel):
    user_id: Optional[str] = None
    storage_path: str
    partner_name: str = "상대방"
    timestamp: str = ""

def save_analysis_to_firestore(user_id: str, data: dict, date_str: Optional[str] = None):
    if not db: return
    try:
        if not date_str: date_str = datetime.now().strftime("%Y-%m-%d")
        target_ref = db.collection("users").document(user_id).collection("daily_logs").document(date_str)
        payload = data
        if cipher:
            encrypted = CryptoManager.encrypt_data(data)
            if encrypted: payload = encrypted
        target_ref.set({"user_id": user_id, "date": date_str, "logs": firestore.ArrayUnion([payload]), "last_updated": firestore.SERVER_TIMESTAMP}, merge=True)
        print(f"[Firestore 저장] 완료: {date_str}")
    except Exception as e: print(f"[Firestore 저장] 오류: {e}")

# ==========================================
# 3. 클래스 정의 (최적화 + Lazy Loading)
# ==========================================

class VoiceAuthenticator:
    def __init__(self, model_dir=None):
        # ★ Cloud Run 호환: /tmp 경로 사용 (읽기 전용 파일 시스템 우회)
        self.user_voice_dir = os.path.join(TMP_CACHE_DIR, "user_voices")
        self.model_dir = model_dir or os.path.join(TMP_CACHE_DIR, "pretrained_models")
        self.model = None
        os.makedirs(self.user_voice_dir, exist_ok=True)
        os.makedirs(self.model_dir, exist_ok=True)

    def load_model(self):
        """요청 시에만 모델을 로드 (Lazy Loading) - 강력한 호환성 패치 적용"""
        if self.model is not None: return
        try:
            import torchaudio
            import soundfile as sf
            import torch

            #torchaudio 구버전/신버전 호환성 강제 주입
            if not hasattr(torchaudio, "list_audio_backends"):
                # 함수가 없으면 강제로 만듭니다.
                setattr(torchaudio, "list_audio_backends", lambda: ["soundfile"])

            if not hasattr(torchaudio, "get_audio_backend"):
                 setattr(torchaudio, "get_audio_backend", lambda: "soundfile")

            # [패치 2] 리눅스/Cloud Run 환경에서 SoundFile 백엔드 강제 설정
            try:
                torchaudio.set_audio_backend("soundfile")
            except:
                pass

            # 패치 적용 후 SpeechBrain 임포트
            from speechbrain.inference.speaker import SpeakerRecognition

            # torchaudio load 함수 오버라이딩 (안전 장치)
            def _force_soundfile_load(filepath, *args, **kwargs):
                data, samplerate = sf.read(filepath)
                tensor = torch.from_numpy(data).float()
                return tensor, samplerate
            torchaudio.load = _force_soundfile_load

            self.model = SpeakerRecognition.from_hparams(
                source="speechbrain/spkrec-ecapa-voxceleb",
                savedir=os.path.join(self.model_dir, "spkrec-ecapa-voxceleb"),
                run_opts={"device": "cpu"}
            )
            print("성문 분석 모델 로딩 완료!")
        except Exception as e:
            print(f"[VoiceAuth] 모델 로딩 실패: {e}")
            import traceback; traceback.print_exc() # 상세 에러 로그 출력
            self.model = "ERROR"

    def ensure_user_voice_exists(self, user_id: str):
        final_wav_path = os.path.join(self.user_voice_dir, f"{user_id}.wav")

        # 1. 이미 변환된 파일이 정상이면 사용
        if os.path.exists(final_wav_path) and os.path.getsize(final_wav_path) > 1000:
            return True

        if not bucket: return False
        print(f"🔍 [VoiceAuth] '{user_id}' 기준 목소리 다운로드...")

        # 2. Storage 파일 탐색 (확장자 무관하게 다 찾기)
        prefix = f"Users/{user_id}/source/user_voice/"
        blobs = list(bucket.list_blobs(prefix=prefix))

        target_blob = None
        # 용량이 너무 작지 않은(1KB 이상) 오디오 파일 찾기
        for b in blobs:
            if b.size is not None and b.size > 1000: # 1KB 이상
                target_blob = b
                break

        # 레거시 경로 확인
        if not target_blob:
            legacy_prefix = "users_recognition/"
            blobs_legacy = list(bucket.list_blobs(prefix=legacy_prefix))
            for b in blobs_legacy:
                if f"{user_id}" in b.name and b.size > 1000:
                    target_blob = b
                    break

        if not target_blob:
            print(f"   ❌ 유효한 목소리 파일이 없습니다.")
            return False

        # 3. 임시 다운로드
        temp_ext = os.path.splitext(target_blob.name)[1] or ".tmp"
        temp_path = os.path.join(self.user_voice_dir, f"temp_origin_{user_id}{temp_ext}")
        target_blob.download_to_filename(temp_path)

        # 4. [핵심] 무차별 포맷 대입 (ffmpeg 에러 183 해결)
        from pydub import AudioSegment
        audio = None

        # 시도해볼 포맷 리스트 (순서대로)
        formats_to_try = [None, 'm4a', 'wav', 'mp3', 'webm', 'ogg', 'flac', 'mp4']

        for fmt in formats_to_try:
            try:
                if fmt is None:
                    audio = AudioSegment.from_file(temp_path) # 자동 감지
                else:
                    audio = AudioSegment.from_file(temp_path, format=fmt) # 강제 지정

                if audio:
                    print(f" 포맷 감지 성공: {fmt if fmt else 'Auto'}")
                    break
            except:
                continue

        if audio:
            # 변환 성공 시 저장
            audio = audio.set_frame_rate(16000).set_channels(1)
            audio.export(final_wav_path, format="wav")
            if os.path.exists(temp_path): os.remove(temp_path)
            return True
        else:
            print(f" ❌ [Fatal] 모든 포맷으로 디코딩 실패. 파일이 손상되었습니다.")
            if os.path.exists(temp_path): os.remove(temp_path)
            return False

    def identify_speaker(self, user_id: str, call_audio_path: str, segments: list, user_name: str = "나") -> dict:
        """
        verify_files를 사용하여 화자 식별.
        user_name: 식별 성공 시 반환할 이름 (기본값: "나")
        """
        self.load_model()
        if not self.model or self.model == "ERROR": return {}

        if not self.ensure_user_voice_exists(user_id):
            return {}

        user_anchor_path = os.path.join(self.user_voice_dir, f"{user_id}.wav")
        safe_wav_path = call_audio_path + ".converted.wav"
        temp_dir = tempfile.mkdtemp()

        mapping = {}
        try:
            from pydub import AudioSegment
            # 통화 오디오 전처리
            original_audio = AudioSegment.from_file(call_audio_path)
            converted_audio = original_audio.set_frame_rate(16000).set_channels(1)
            converted_audio.export(safe_wav_path, format="wav")
            full_audio = AudioSegment.from_file(safe_wav_path)

            # 화자별 최장 발화 구간 추출
            best_segments = {}
            for seg in segments:
                spk = seg.get('speaker', {}).get('name', 'Unknown')
                start, end = int(seg.get('start', 0)), int(seg.get('end', 0))
                duration = end - start
                if duration < 1000: continue  # 1초 미만 구간 무시

                if spk not in best_segments or duration > best_segments[spk]['duration']:
                    best_segments[spk] = {'start': start, 'end': end, 'duration': duration}

            scores = {}
            for spk, time_info in best_segments.items():
                clip = full_audio[time_info['start']:time_info['end']]
                clip_path = os.path.join(temp_dir, f"clip_{spk}.wav")
                clip.export(clip_path, format="wav")

                # [핵심] SpeechBrain 검증 함수 사용
                score, prediction = self.model.verify_files(user_anchor_path, clip_path)
                scores[spk] = score.item()

            if not scores: return {}

            # 점수가 가장 높은 화자를 본인으로 식별
            identified_user_spk = max(scores, key=scores.get)

            # [변경] "me" 대신 전달받은 user_name 사용
            for spk in scores.keys():
                mapping[spk] = user_name if spk == identified_user_spk else "partner"

            print(f"[화자 식별] 성공: {mapping} (Max Score: {scores[identified_user_spk]:.4f})")
            return mapping

        except Exception as e:
            print(f"[화자 식별] 오류 발생: {e}")
            return {}
        finally:
            if os.path.exists(safe_wav_path): os.remove(safe_wav_path)
            if os.path.exists(temp_dir): shutil.rmtree(temp_dir)

class SMSAnalyzer:
    def __init__(self, client, max_concurrent: int = 10):
        self.client = client
        self.url_pattern = re.compile(r'https?://(?:[-\w.]|(?:%[\da-fA-F]{2}))+[/\w\.-]*')
        self.max_concurrent = max_concurrent
        self._semaphore = None

    def _get_semaphore(self):
        if self._semaphore is None:
            self._semaphore = asyncio.Semaphore(self.max_concurrent)
        return self._semaphore

    async def fetch_website_content(self, session: aiohttp.ClientSession, url: str) -> str:
        if not url: return None
        try:
            async with session.get(url, timeout=3, ssl=False) as resp:
                if resp.status != 200: return f"접속실패({resp.status})"
                html = await resp.text()
                clean_text = re.sub(r'<[^>]+>', ' ', html)
                return ' '.join(clean_text.split())[:500]
        except asyncio.TimeoutError:
            return "접속불가(타임아웃)"
        except Exception as e:
            return "접속불가"

    async def analyze_messages(self, messages: List[Dict]) -> List[Dict]:
        if not messages: return []
        async with aiohttp.ClientSession() as session:
            valid_messages = [msg for msg in messages if isinstance(msg, dict)]
            tasks = [self._analyze_single(msg, session) for msg in valid_messages]
            results = await asyncio.gather(*tasks, return_exceptions=True)

            processed = []
            for i, res in enumerate(results):
                if isinstance(res, Exception):
                    msg = valid_messages[i]
                    processed.append({
                        "partner": msg.get('sender_name', 'Unknown'),
                        "msg": msg.get('content', ''),
                        "error": str(res)
                    })
                else: processed.append(res)
            return processed

    async def _analyze_single(self, message: Dict, session: aiohttp.ClientSession):
        semaphore = self._get_semaphore()
        async with semaphore:
            # 1. 원본 메시지 데이터 복사 (app_name, package_name 등 보존)
            result_data = message.copy()

            # 2. 분석에 필요한 필드 추출
            partner = (message.get('sender_name') or message.get('sender_phone') or message.get('partner') or "알 수 없음")
            content = (
                message.get('content') or
                message.get('msg') or
                message.get('message_body') or
                ''
            )
            timestamp = (message.get('timestamp') or '시간 미상')

            if not content:
                result_data["error"] = "내용 없음"
                return result_data

            # (웹사이트 콘텐츠 가져오기 로직은 그대로 유지...)
            website_info = ""
            url_match = self.url_pattern.search(content)
            if url_match:
                site_content = await self.fetch_website_content(session, url_match.group())
                if site_content: website_info = f"\n[참고 URL 내용]: {site_content}"

            # ★ 프롬프트 유지
            prompt = f"""
            너는 한국어 SMS 분석 전문가다. 아래 메시지를 분석하여 JSON으로 응답하라.

            [메시지 정보]
            - 발신자: {partner}
            - 수신시간: {timestamp}
            - 내용: {content}
            {website_info}

            [분석 지침]
            1. 일정(Schedule): 구체적 행동+특정 시점이 있어야 함. 질문형, 영업안내는 제외.
            2. 피싱(Phishing): URL, 금전요구, 사칭 등.
            3. 데이터 추출: 날짜는 YYYY-MM-DD HH:MM 형식.
            """

            try:
                response = await self.client.aio.models.generate_content(
                    model="gemini-3-flash-preview",
                    contents=prompt,
                    config=types.GenerateContentConfig(
                        response_mime_type="application/json",
                        response_schema={
                            "type": "OBJECT",
                            "properties": {
                                "is_phishing": {"type": "BOOLEAN"},
                                "phishing_reason": {"type": "STRING"},
                                "is_schedule": {"type": "BOOLEAN"},
                                "schedule_summary": {"type": "STRING"},
                                "schedule_datetime": {"type": "STRING"},
                                "schedule_location": {"type": "STRING"}
                            }
                        }
                    )
                )
                raw_text = response.text.strip()
                if raw_text.startswith("```"): raw_text = re.sub(r"^```json|^```", "", raw_text).strip()
                if raw_text.endswith("```"): raw_text = raw_text[:-3].strip()
                ai_res = json.loads(raw_text)

                #원본 데이터에 분석 결과
                result_data["analysis"] = ai_res
                result_data["media_type"] = "sms"
                # 파트너 정보가 없으면 채워넣기
                if "partner" not in result_data: result_data["partner"] = partner

                return result_data
            except Exception as e:
                result_data["error"] = str(e)
                return result_data
# ==========================================
# 4. 공통 함수
# ==========================================

async def run_clova_stt(audio_bytes: bytes) -> dict:
    print(f"[Clova] STT 요청 시작 (크기: {len(audio_bytes)} bytes)")

    if not CLOVA_INVOKE_URL:
        print("[Clova] URL이 설정되지 않음")
        return {"text": "", "segments": []}

    # URL 끝에 /recognizer/upload 가 없으면 자동으로 붙여줌
    target_url = CLOVA_INVOKE_URL
    if not target_url.endswith("/recognizer/upload"):
        target_url = f"{target_url.rstrip('/')}/recognizer/upload"

    headers = {'X-CLOVASPEECH-API-KEY': CLOVA_SECRET_KEY}
    params = {
        'language': 'ko-KR',
        'completion': 'sync',
        'diarization': {'enable': True, 'speakerCountMin': 1, 'speakerCountMax': 2}
    }

    loop = asyncio.get_event_loop()

    def _request():
        try:
            # 타임아웃을 120초로 설정
            return requests.post(
                target_url,
                headers=headers,
                files={'media': ('audio.m4a', audio_bytes), 'params': (None, json.dumps(params), 'application/json')},
                timeout=120
            )
        except Exception as e:
            print(f"[Clova] 요청 중 네트워크 오류: {e}")
            return None

    try:
        res = await loop.run_in_executor(None, _request)

        #실패 시 에러 코드를 로그에 출력
        if res is None:
            return {"text": "", "segments": []}

        if res.status_code != 200:
            print(f"[Clova] API 호출 실패!")
            print(f"   - 상태 코드: {res.status_code}")
            print(f"   - 응답 본문: {res.text}")  #에러 메시지 출력
            return {"text": "", "segments": []}

        result = res.json()
        text = result.get("text", "")
        segments = result.get("segments", [])

        if segments:
            lines = []
            for s in segments:
                speaker_name = s.get('speaker', {}).get('name', 'Unknown')
                utterance = s.get('text', '')
                lines.append(f"{speaker_name}: {utterance}")
            text = "\n".join(lines)
        return {"text": text, "segments": segments}

    except Exception as e:
        print(f"[Clova] 처리 중 예외 발생: {e}")
        return {"text": "", "segments": []}

async def refine_transcript_gemini(text: str) -> str:
    if not text: return ""
    prompt = f"""아래 통화 녹음 텍스트를 오타 수정하고 자연스럽게 다듬어 주세요.
    중요: 설명이나 주석을 절대 추가하지 말고, 보정된 통화 텍스트만 반환하세요.

    {text}"""
    try:
        if not genai_client: return text
        response = await genai_client.aio.models.generate_content(
            model="gemini-3-flash-preview",
            contents=prompt,
            config=types.GenerateContentConfig(temperature=0.2)
        )
        return response.text.strip()
    except: return text

async def analyze_transcript_comprehensive(text: str) -> dict:
    if not text or len(text) < 20: return {}
    # ★ 프롬프트 & JSON 포맷 유지
    prompt = f"""
    당신은 통화 녹음 분석 전문가입니다. 아래 [통화 텍스트]를 분석하여 다음 두 가지 종류의 '결정적 순간'을 추출하세요.

    [분석 목표]
    1. **calendar_event (일정):** - "오늘", "내일", "이번 주말" 같은 상대적 단어 절대 금지.
       - 반드시 **"YYYY-MM-DD HH:MM"** (예: 2026-02-08 19:00) 형식으로 변환해서 출력하세요.
       - 연도를 알 수 없으면 현재 연도(2026)를 기준으로 추론하세요.
       - 일정이 없으면 빈 문자열("")로 두세요.

    2. **emotional_highlight (기억에 남을 순간):**
           다음 중 하나라도 해당되면 추출하세요:

           [따뜻한 감성]
           - "사랑해", "좋아해", "보고 싶어" 등의 애정 표현
           - "고마워", "수고했어", "힘내" 등의 따뜻한 위로와 격려, 감사 표현

           [재미있는 순간]
           - 웃음을 유발하는 농담이나 유머
           - 재치 있는 대화, 장난스러운 티키타카
           - "ㅋㅋ", "웃겨", "진짜?" 등 웃음 반응이 나온 부분

           [흥미로운 이야기]
           - 새로운 소식이나 놀라운 정보 공유
           - "알아?", "들었어?", "신기하게도" 등으로 시작하는 흥미로운 내용
           - 상대방이 관심을 보인 주제

           [추억/과거 이야기]
           - "그때 기억나?", "예전에", "옛날에" 등 과거 회상
           - 함께한 추억을 떠올리는 대화
           - 가족, 친구, 연인과의 소중한 기억

           [의미 있는 대화]
           - 서로의 근황을 나누는 내용
           - 고민 상담이나 조언
           - 중요한 결심이나 다짐을 나누는 순간

           - 위 카테고리 중 가장 인상적인 순간 하나를 선택하세요.
           - 없을 경우 빈 문자열("")로 두세요.

    3.**calendar_event (일정):** - "spam" 유형일 경우 절대 추출하지 마세요. (빈 문자열)
       - 그 외: 구체적인 약속(시간, 장소)이나 예약 확정일 때만 추출.

    [제약 사항]
    1. **원문 유지:** 추출한 텍스트는 오타가 있어도 원문 그대로 가져오세요.
    2. **분량:** emotional_highlight 는 1~2문장 내외로 짧게.
    3. **내용:**:  calendar_event는 구체적이고 명확학 약속/ 정보 전달이여야 함.
    4. **형식:** 반드시 아래 JSON 포맷을 준수하세요.

    - 지역 번호(02, 031)나 일반 번호(010)로 온 전화라도, 내용이 '인터넷 가입', '지원금', '대출' 권유라면 반드시 "spam"으로 분류하세요.

    [통화 텍스트]
    {text}

    [출력 JSON 형식] - 반드시 단일 객체로 반환
    {{
        "emotional": {{
            "text": "오늘 하루도 진짜 고생 많았어, 푹 쉬어.",
            "reason": "상대방에 대한 따뜻한 위로와 격려"
        }},
        "calendar_event": {{
            "content": "그럼 다음 주 화요일 오후 3시에 카페에서 만나자.",
            "datetime": "2026-02-08 19:00",  <-- 반드시 이 형식 준수!
            "location": "카페"
        }}
    }}
    """
    try:
        response = await genai_client.aio.models.generate_content(
            model="gemini-3-flash-preview",
            contents=prompt,
            config=types.GenerateContentConfig(response_mime_type="application/json", temperature=0.3)
        )
        result = json.loads(response.text)
        if isinstance(result, list):
            merged = {}
            for i in result: merged.update(i)
            return merged
        return result
    except: return {}

# Helper Functions (클립 생성 등)
async def clip_audio_segment(original_audio_path: str, start_ms: int, end_ms: int, user_id: str, prefix: str = "highlight") -> str:
    if start_ms >= end_ms: return ""
    try:
        from pydub import AudioSegment
        audio = AudioSegment.from_file(original_audio_path)
        clip = audio[max(0, start_ms-500):min(len(audio), end_ms+500)]
        filename = f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp3"
        temp_path = os.path.join(tempfile.gettempdir(), filename)
        clip.export(temp_path, format="mp3")

        if bucket:
            blob = bucket.blob(f"Users/{user_id}/result/highlights/{filename}")
            blob.upload_from_filename(temp_path)
            blob.make_public()
            return blob.public_url
        return ""
    except Exception as e:
        print(f"Clip Error: {e}")
        return ""

def find_highlight_times(highlight_text: str, segments: list) -> tuple:
    """하이라이트 텍스트가 포함된 세그먼트 시간 찾기 (로컬 로직 적용)"""
    if not highlight_text or not segments:
        return 0, 0

    clean_text = highlight_text
    if ":" in highlight_text:
        clean_text = highlight_text.split(":", 1)[1]
    target = clean_text.replace(" ", "").strip()

    if len(target) < 3: return 0, 0

    start_idx = -1

    # 1. 앞부분 매칭
    start_snippet = target[:min(len(target), 15)]
    for i, seg in enumerate(segments):
        if start_snippet in seg.get('text', '').replace(" ", ""):
            start_idx = i
            break

    # 2. 청크 매칭 (Fallback)
    if start_idx == -1:
        for chunk_size in [10, 7, 5]:
            for offset in range(0, min(len(target), 30), chunk_size):
                chunk = target[offset:offset+chunk_size]
                if len(chunk) < 4: continue
                for i, seg in enumerate(segments):
                    if chunk in seg.get('text', '').replace(" ", ""):
                        start_idx = i
                        break
                if start_idx != -1: break
            if start_idx != -1: break

    if start_idx == -1:
        # 못 찾으면 중간 지점 반환 (안전 장치)
        if len(segments) > 2:
            mid = len(segments) // 2
            return int(segments[mid-1].get('start', 0)), int(segments[mid+1].get('end', 0))
        return 0, 0

    # 종료 지점 계산
    accumulated = ""
    end_idx = start_idx
    for i in range(start_idx, len(segments)):
        accumulated += segments[i].get('text', '').replace(" ", "")
        end_idx = i
        if len(accumulated) >= len(target) * 0.7: break

    return int(segments[start_idx].get('start', 0)), int(segments[end_idx].get('end', 0))

def save_calendar_event(user_id: str, calendar_data: dict, partner: str, call_timestamp: str):
    """
    [일정 하이라이트 저장]
    - 수정사항: AI가 '오늘', '내일' 등으로 날짜를 줘도 문서 ID는 무조건 'YYYY-MM-DD' 형식을 지키도록 강제함.
    """
    if not calendar_data or not calendar_data.get("content"):
        return

    if db:
        try:
            col_ref = db.collection('users').document(user_id).collection('calendar_events')

            ai_datetime = calendar_data.get("datetime", "").strip()

            # 정규식으로 YYYY-MM-DD 패턴 추출
            date_match = re.search(r"(\d{4}-\d{2}-\d{2})", ai_datetime)

            if date_match:
                # 2026-02-08 19:00 -> 2026-02-08 (무조건 날짜만 추출)
                final_date_id = date_match.group(1)
            else:
                # AI가 실패했거나 형식이 이상하면 -> 통화 타임스탬프 사용
                print(f"⚠️ 날짜 형식 오류('{ai_datetime}'). 통화 시간으로 대체합니다.")
                if call_timestamp:
                    final_date_id = str(call_timestamp)[:10] # 2026-02-08...
                else:
                    final_date_id = datetime.now().strftime("%Y-%m-%d")

            # 문서 ID는 무조건 YYYY-MM-DD
            doc_id = final_date_id

            # 3. 데이터 구성
            event_data = {
                "source": "call",
                "summary": calendar_data.get("content", "통화 일정"),
                "datetime": ai_datetime if date_match else f"{doc_id} (시간 미정)", # 원본 정보 보존
                "location": calendar_data.get("location", ""),
                "partner": partner,
                "call_timestamp": call_timestamp,
                "calendar_audio_url": calendar_data.get("calendar_audio_url", ""),
                "is_notified": False,
                "travel_notified": False,
                "dest_lat": None,
                "dest_lng": None
            }

            # 4. 암호화 및 저장
            encrypted_event = CryptoManager.encrypt_data(event_data) if cipher else event_data

            col_ref.document(doc_id).set({
                "user_id": user_id,
                "date": doc_id,
                "events": firestore.ArrayUnion([encrypted_event]),
                "last_updated": firestore.SERVER_TIMESTAMP
            }, merge=True)

            print(f"📅 [Calendar] Firestore 저장 완료: {doc_id} (AI 원본: {ai_datetime})")

        except Exception as e:
            print(f"⚠️ [Calendar] Firestore 저장 실패: {e}")

def save_sms_by_category(user_id: str, results: List[Dict]) -> List[Dict]:
    """
    [SMS 저장]
    - 로컬 코드 기반: timestamp 필드 추가 및 안전한 기본값 처리 적용
    - [수정 사항]: 피싱 메시지 DB 저장 로직 삭제 및 사용자/보호자 FCM 알림 추가
    """
    categories = {"phishing": [], "schedule": [], "general": []}

    for result in results:
        if 'error' in result:
            categories["general"].append(result)
            continue

        analysis = result.get('analysis', {})
        if analysis.get('is_phishing'): categories["phishing"].append(result)
        elif analysis.get('is_schedule'): categories["schedule"].append(result)
        else: categories["general"].append(result)

    if db:
        # [1] Schedule 저장
        if categories["schedule"]:
            try:
                col_ref = db.collection('users').document(user_id).collection('calendar_events')
                for msg in categories["schedule"]:
                    an = msg.get('analysis', {})
                    schedule_datetime = an.get('schedule_datetime', '')

                    if schedule_datetime:
                        if " " in schedule_datetime:
                            doc_id = schedule_datetime.split()[0]
                        else:
                            doc_id = schedule_datetime[:10] if len(schedule_datetime) >= 10 else schedule_datetime

                        event_data = {
                            "source": "sms",
                            "summary": an.get('schedule_summary', '일정'),
                            "datetime": schedule_datetime,
                            "location": an.get('schedule_location', ''),
                            "original_text": msg.get('msg', ''),
                            "partner": msg.get('partner', ''),
                            "timestamp": msg.get('timestamp', ''),
                            "is_notified": False
                        }

                        encrypted_event = CryptoManager.encrypt_data(event_data) if cipher else event_data

                        col_ref.document(doc_id).set({
                            "user_id": user_id,
                            "date": doc_id,
                            "events": firestore.ArrayUnion([encrypted_event]),
                            "last_updated": firestore.SERVER_TIMESTAMP
                        }, merge=True)
            except Exception as e:
                print(f"SMS 일정 저장 실패: {e}")

        # [2] Phishing 감지
        if categories["phishing"]:
            try:
                # 1. 토큰 가져오기 (사용자 & 보호자)
                user_doc = db.collection('users').document(user_id).get()
                user_fcm_token = None
                guardian_fcm_token = None

                if user_doc.exists:
                    user_data = user_doc.to_dict()
                    user_fcm_token = user_data.get('fcm_token')          # 사용자 본인 토큰
                    guardian_fcm_token = user_data.get('guardian_fcm_token') # 보호자 토큰

                # 2. 알림 전송
                for msg in categories["phishing"]:
                    alert_title = "[긴급] 피싱 위험 알림"
                    alert_body = f"피싱 의심 문자 감지! \n내용: {msg.get('msg', '')[:30]}..."

                    timestamp_str = str(msg.get('timestamp', ''))
                    # (A) 사용자에게 전송
                    if user_fcm_token:
                        try:
                            message_user = messaging.Message(
                                notification=messaging.Notification(title=alert_title, body=alert_body),
                                data={"type": "phishing_alert", "user_id": user_id, "timestamp": timestamp_str},
                                token=user_fcm_token
                            )
                            messaging.send(message_user)
                            print(f"사용자({user_id})에게 피싱 알림 전송 완료")
                        except Exception as fe:
                            print(f"❌ 사용자 알림 실패: {fe}")

                    # (B) 보호자에게 전송
                    if guardian_fcm_token:
                        try:
                            message_guardian = messaging.Message(
                                notification=messaging.Notification(title=alert_title, body=f"[보호자 알림] {alert_body}"),
                                data={"type": "phishing_alert_guardian", "user_id": user_id, "timestamp": timestamp_str},
                                token=guardian_fcm_token
                            )
                            messaging.send(message_guardian)
                            print(f"🔔 보호자에게 피싱 알림 전송 완료")
                        except Exception as fe:
                            print(f"❌ 보호자 알림 실패: {fe}")

            except Exception as e:
                print(f"피싱 처리 중 오류 발생: {e}")

    # 일반 메시지 반환
    return categories["general"]

# ★ KeyBERT Lazy Loading Wrapper
def get_keywords(text: str):
    if not text: return []
    if global_models["keybert"] is None:
        try:
            from keybert import KeyBERT
            global_models["keybert"] = KeyBERT('paraphrase-multilingual-MiniLM-L12-v2')
        except: global_models["keybert"] = "ERROR"
    if global_models["keybert"] == "ERROR": return []
    return global_models["keybert"].extract_keywords(text, top_n=5)

# ★ Core Logic
async def process_core_logic(file_path: str, user_id: str, partner_name: str, timestamp: str):
    filename = file_path.lower()

    if filename.endswith(".json"):
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        msgs = data if isinstance(data, list) else data.get('messages', [data])
        analyzer = SMSAnalyzer(genai_client)
        results = await analyzer.analyze_messages(msgs)
        return {"type": "sms", "results": results}

    elif filename.endswith((".m4a", ".wav", ".mp3", ".aac", ".amr", ".ogg", ".flac", ".opus")):
        with open(file_path, "rb") as f: audio_bytes = f.read()

        # 1. STT
        stt = await run_clova_stt(audio_bytes)
        raw_text = stt.get("text", "")
        segments = stt.get("segments", [])

        # 2. 화자 식별 (Lazy Loading)
        if global_models["voice_auth"] is None:
            global_models["voice_auth"] = VoiceAuthenticator()

        mapping = {}
        try:
            if segments:
                # 1. Firestore에서 실명 조회 (비동기 래핑)
                # DB 조회는 동기 방식이므로 asyncio.to_thread로 감싸서 서버 멈춤 방지
                real_name = await asyncio.to_thread(get_user_real_name, user_id)
                print(f"👤 식별된 사용자 이름: {real_name}")

                # 2. 조회한 real_name을 user_name 인자로 전달
                # ★ [Cloud Run 호환] 동기 함수를 to_thread로 감싸서 이벤트 루프 블로킹 방지
                mapping = await asyncio.to_thread(
                    global_models["voice_auth"].identify_speaker,
                    user_id,
                    file_path,
                    segments,
                    real_name  # user_name 인자
                )
        except Exception as e: print(f"[화자 식별] 오류 발생: {e}")

        # ★ 사용자 실명 확보 (화자 식별 성공/실패 불문)
        user_display_name = "나"
        if mapping:
            for spk, role in mapping.items():
                if role != "partner":
                    user_display_name = role
                    break
        else:
            # 화자 식별 실패했어도 DB에서 이름 조회
            try:
                user_display_name = await asyncio.to_thread(get_user_real_name, user_id)
            except:
                pass

        # 1차 치환: Clova 원본(speaker1 등) → 이름
        processed_text = raw_text
        if mapping:
            for spk, role in mapping.items():
                name = partner_name if role == "partner" else role
                processed_text = re.sub(f"(^|\n){re.escape(spk)}:", f"\\1{name}:", processed_text)

        # 3. Gemini 텍스트 보정
        refined_text = await refine_transcript_gemini(processed_text)

        # ★ [Fix] Gemini 보정 후 A/B 등 generic 레이블이 남아있으면 강제 치환
        label_pattern = re.findall(r'^([A-Za-z가-힣]+\d*)\s*:', refined_text, re.MULTILINE)
        unique_labels = list(dict.fromkeys(label_pattern))  # 순서 유지 중복 제거

        # 이미 올바른 이름이 들어간 레이블 제외
        known_names = {partner_name, user_display_name}
        unknown_labels = [l for l in unique_labels if l not in known_names]

        if unknown_labels:
            if mapping:
                # 화자 식별 성공했지만 Gemini가 레이블을 바꾼 경우
                # mapping의 순서와 unknown_labels 순서를 매칭
                mapped_values = list(mapping.values())
                for i, label in enumerate(unknown_labels):
                    if i < len(mapped_values):
                        name = partner_name if mapped_values[i] == "partner" else mapped_values[i]
                    else:
                        name = partner_name if i > 0 else user_display_name
                    refined_text = re.sub(rf'(^|\n){re.escape(label)}\s*:', rf'\1{name}:', refined_text)
                print(f"🔄 [Fix] Gemini 레이블 치환: {unknown_labels} → 이름 적용")
            elif len(unknown_labels) >= 2:
                # 화자 식별 실패 → 첫 번째=사용자, 두 번째=상대방 (Fallback)
                refined_text = re.sub(
                    rf'(^|\n){re.escape(unknown_labels[0])}\s*:',
                    rf'\1{user_display_name}:', refined_text)
                refined_text = re.sub(
                    rf'(^|\n){re.escape(unknown_labels[1])}\s*:',
                    rf'\1{partner_name}:', refined_text)
                print(f"⚠️ [Fallback] 화자 식별 실패 → {unknown_labels[0]}={user_display_name}, {unknown_labels[1]}={partner_name}")
            elif len(unknown_labels) == 1:
                refined_text = re.sub(
                    rf'(^|\n){re.escape(unknown_labels[0])}\s*:',
                    rf'\1{user_display_name}:', refined_text)

        # 병렬 처리
        async def _an(): return await analyze_transcript_comprehensive(refined_text)
        async def _kw(): return await asyncio.to_thread(get_keywords, refined_text)

        analysis_res, keywords_raw = await asyncio.gather(_an(), _kw())
        keywords = [k[0] for k in keywords_raw]

        # 일정 & 하이라이트 처리
        cal_info = {}
        cal_data = analysis_res.get("calendar_event")
        if cal_data and cal_data.get("content"):
            s, e = find_highlight_times(cal_data["content"], segments)
            url = ""
            if e > s: url = await clip_audio_segment(file_path, s, e, user_id, "calendar")
            cal_info = {**cal_data, "calendar_audio_url": url}
            save_calendar_event(user_id, cal_info, partner_name, timestamp)

        emo_info = {}
        emo_data = analysis_res.get("emotional")
        if emo_data and emo_data.get("text"):
            s, e = find_highlight_times(emo_data["text"], segments)
            url = ""
            if e > s: url = await clip_audio_segment(file_path, s, e, user_id, "highlight")
            emo_info = {**emo_data, "call_audio_url": url}

        return {
            "media_type": "call",
            "partner": partner_name,
            "content": refined_text,
            "keywords": keywords,
            "highlight": emo_info,
            "calendar_event": cal_info
        }
    else:
        # 파일 이름과 확장자를 포함한 상세 에러 메시지
        file_basename = os.path.basename(file_path)
        file_ext = os.path.splitext(file_path)[1]
        error_msg = f"Unsupported file: '{file_basename}' (extension: '{file_ext or 'none'}')\nSupported: .m4a, .wav, .mp3"
        print(f"❌ {error_msg}")
        raise HTTPException(status_code=400, detail=error_msg)

# ==========================================
# 5. FastAPI App
# ==========================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    print("\n[sms-call-Server] 시작")
    # 서버 시작 시 모델 로드하지 않음 -> Cold Start 방지
    yield
    print("👋 [Server] 종료")

app = FastAPI(lifespan=lifespan)

@app.post("/analyze/upload")
async def analyze_upload_file(bg_tasks: BackgroundTasks, file: UploadFile = File(...), user_id: str = Form(...)):
    temp_path = os.path.join(tempfile.gettempdir(), file.filename)
    with open(temp_path, "wb") as f: f.write(await file.read())

    try:
        res = await process_core_logic(temp_path, user_id, "상대방", "")
        return {"status": "success", "data": res}
    finally:
        if os.path.exists(temp_path): os.remove(temp_path)

@app.post("/analyze/storage")
async def analyze_from_storage(req: StorageAnalysisRequest, bg_tasks: BackgroundTasks):
    if not bucket: raise HTTPException(status_code=500, detail="Firebase Storage 미초기화")

    extracted_uid = extract_uid_from_path(req.storage_path)
    final_user_id = extracted_uid if extracted_uid != "test_user" else (req.user_id or "test_user")
    extracted_date = extract_date_from_filename(os.path.basename(req.storage_path))

    safe_filename = re.sub(r'[^\w.-]', '_', os.path.basename(req.storage_path))
    temp_local_path = os.path.join(tempfile.gettempdir(), f"temp_{final_user_id}_{int(asyncio.get_event_loop().time())}_{safe_filename}")

    try:
        blob = bucket.blob(req.storage_path)
        if not blob.exists(): raise HTTPException(status_code=404, detail="파일 없음")
        blob.download_to_filename(temp_local_path)

        result = await process_core_logic(temp_local_path, final_user_id, req.partner_name, req.timestamp)

        result_type = result.get('type', 'unknown')
        extracted_datetime = extract_datetime_from_filename(os.path.basename(req.storage_path))
        if result_type == 'sms':
            general_messages = save_sms_by_category(final_user_id, result.get('results', []))
            sms_result_for_daily = {
                "type": "sms", "total_count": len(general_messages), "results": general_messages
            }
            bg_tasks.add_task(save_analysis_to_firestore, final_user_id, sms_result_for_daily, extracted_date)
        else:
            # 통화 녹음: 파일명에서 추출한 timestamp 추가
            if extracted_datetime:
                result["timestamp"] = extracted_datetime
            bg_tasks.add_task(save_analysis_to_firestore, final_user_id, result, extracted_date)

        return {"status": "success"}
    finally:
        if os.path.exists(temp_local_path): os.remove(temp_local_path)

# Eventarc Data Model
class GoogleCloudEvent(BaseModel):
    bucket: str
    name: str
    generation: Optional[str] = None      # GCS 업로드마다 고유한 값 (중복 방지 핵심)
    metageneration: Optional[str] = None
    timeCreated: Optional[str] = None
    updated: Optional[str] = None

    class Config:
        extra = "allow"  # GCS가 보내는 추가 필드 무시하지 않음

@app.post("/webhook/gcs")
async def handle_gcs_trigger(event: GoogleCloudEvent, background_tasks: BackgroundTasks):
    file_path = event.name

    # ---------------------------------------------------------
    # 결과 파일 및 처리된 파일 무한 루프 방지
    # ---------------------------------------------------------
    ignore_keywords = ["result/", "processed/", "source/videos/", "source/images/", "source/locations/", "source/users_face/", "source/user_voice/"]
    if any(k in file_path for k in ignore_keywords):
        return {"status": "ignored"}

    # 1. [폴더 필터] 분석 대상 폴더 확인
    target_folders = ["source/calls/", "source/sms_logs/"]
    is_target = False
    for folder in target_folders:
        if folder in file_path:
            is_target = True
            break

    if not is_target:
        # 폴더는 위에서 걸러졌으므로, 여기는 진짜 엉뚱한 파일일 때만 찍힘
        print(f"[Skip] 분석 대상 폴더가 아닙니다: {file_path}")
        return {"status": "skipped", "message": "Not a target folder"}

    print(f"👀 [파일 감지] 경로 확인 중: {file_path}")

    # 2. UID 추론
    user_id = extract_uid_from_path(file_path)
    if not user_id or user_id == "test_user":
        user_id = "unknown_user"

    # ---------------------------------------------------------
    # 파일명 파싱 로직 (3가지 패턴 대응)
    # ---------------------------------------------------------
    raw_filename = os.path.basename(file_path)
    # Mac/Linux 자소 분리 해결 (NFC)
    filename = unicodedata.normalize('NFC', raw_filename)
    base_name = os.path.splitext(filename)[0] # 확장자 제거 (.m4a)

    # 확장자를 명확하게 추출 (소문자로 변환)
    _, file_extension = os.path.splitext(filename)
    file_extension = file_extension.lower()

    partner_name = "상대방" # 기본값

    try:
        if re.match(r"^통화\s*녹음", base_name):
            # '통화녹음' 글자 제거
            clean_name = re.sub(r"^통화\s*녹음", "", base_name).strip()
            # 맨 앞에 혹시 모를 '_' 제거 (예: 통화녹음_홍길동...)
            clean_name = clean_name.lstrip('_')
            # 첫 번째 '_' 앞부분이 이름/번호
            partner_name = clean_name.split('_')[0]
        else:
            # T전화 패턴 ( _ 로 구분됨 )
            parts = base_name.split('_')

            # 패턴 2: {이름}_{번호}_{날짜}_{시간} -> 4덩어리 이상
            # 예: 홍길동_01012345678_250127_120000
            if len(parts) >= 4:
                partner_name = parts[0] # 첫 번째가 이름

            # 패턴 3: {번호}_{날짜}_{시간} -> 3덩어리
            # 예: 01012345678_250127_120000
            elif len(parts) == 3:
                partner_name = parts[0] # 첫 번째가 번호

            # 그 외 (알 수 없는 형식) -> 그냥 첫 번째 덩어리 사용
            else:
                partner_name = parts[0]

        if partner_name:
            if partner_name.startswith("070") or partner_name.startswith("070-"):
                print(f"[Spam Filter] 070 광고성 번호 감지: {partner_name} -> 분석 건너뜀")
                return {"status": "skipped", "message": "Spam number (070)"}

            # 전화번호 패턴이면 "상대방"으로 치환
            if re.match(r"^0\d{8,10}$", partner_name):
                print(f"📞 [Format] 전화번호 감지: {partner_name} -> '상대방'으로 표시")
                partner_name = "상대방"
        else:
            partner_name = "상대방"

        print(f"식별된 상대방: {partner_name} (타입: {file_extension})")

    except Exception as e:
        print(f"이름 파싱 중 오류({e}), 기본값 사용")

    # ---------------------------------------------------------
    # 3. 중복 방지 (Firestore 트랜잭션으로 원자적 잠금)
    # ---------------------------------------------------------
    # ★ [Fix] generation을 포함하여 같은 경로라도 새 업로드는 새로운 ID 생성
    # generation: GCS 업로드마다 고유 → 같은 경로 재업로드 시 다른 file_id
    # 같은 업로드의 중복 이벤트는 동일 generation → 같은 file_id로 중복 차단
    dedup_key = file_path
    if event.generation:
        dedup_key = f"{file_path}_{event.generation}"
    elif event.timeCreated:
        dedup_key = f"{file_path}_{event.timeCreated}"
    file_id = hashlib.md5(dedup_key.encode('utf-8')).hexdigest()
    print(f"🔑 [Dedup] key={dedup_key[:80]}... → ID={file_id}")
    import datetime as dt

    processed_ref = None
    if db:
        try:
            processed_ref = db.collection('users').document(user_id).collection('processed_files').document(file_id)

            # ★ 트랜잭션으로 원자적 잠금 (Race Condition 해결)
            @gc_firestore.transactional
            def acquire_lock(transaction, doc_ref, f_path, f_name):
                doc = doc_ref.get(transaction=transaction)

                if doc.exists:
                    data = doc.to_dict()
                    status = data.get("status")

                    # [좀비 잠금 해결] 10분 지난 'processing'은 재시도 허용
                    processed_at = data.get("processed_at")
                    is_stale = False
                    if status == "processing" and processed_at:
                        now = dt.datetime.now(dt.timezone.utc)
                        if (now - processed_at).total_seconds() > 600:  # 10분
                            is_stale = True
                            print(f"⚠️ [Stale Lock] 좀비 잠금 감지 - 재처리 허용: {f_name}")

                    if status == "success":
                        return "already_success"
                    if status == "processing" and not is_stale:
                        return "already_processing"

                # 잠금 획득 (트랜잭션으로 원자적 처리)
                transaction.set(doc_ref, {
                    "file_path": f_path,
                    "file_name": f_name,
                    "processed_at": gc_firestore.SERVER_TIMESTAMP,
                    "status": "processing"
                })
                return "locked"

            transaction = db.transaction()
            lock_result = acquire_lock(transaction, processed_ref, file_path, filename)

            if lock_result == "already_success":
                print(f"✅ [Skip] 이미 처리 완료된 파일: {filename}")
                return {"status": "skipped", "message": "Already success"}
            elif lock_result == "already_processing":
                print(f"🔒 [Skip] 다른 인스턴스가 처리 중: {filename}")
                return {"status": "skipped", "message": "Already processing"}

            print(f"🔐 [Lock] 처리 잠금 획득: {filename}")

        except Exception as e:
            print(f"⚠️ 중복 검사 에러(계속 진행): {e}")
            import traceback; traceback.print_exc()

    # 4. 다운로드 및 분석
    temp_local_path = None
    try:
        if not bucket:
            print(f"❌ [Error] Storage bucket이 None입니다! STORAGE_BUCKET_NAME 환경변수를 확인하세요.")
            print(f"   현재 STORAGE_BUCKET_NAME = {STORAGE_BUCKET_NAME}")
            if processed_ref:
                processed_ref.update({"status": "failed", "error": "bucket is None"})
            return {"status": "error", "message": "Storage bucket not initialized"}

        blob = bucket.blob(file_path)
        if not blob.exists():
            print(f"❌ [Error] blob.exists() = False. 파일 경로: {file_path}")
            raise Exception(f"파일이 존재하지 않습니다 (404): {file_path}")

        # 임시 파일 저장 시 '원본 확장자'를 반드시 유지
        # 확장자가 없으면 경고하고 스킵
        if not file_extension:
            print(f"⚠️ [Skip] 확장자가 없는 파일: {filename}")
            if processed_ref:
                processed_ref.update({"status": "failed", "error": "No file extension"})
            return {"status": "error", "message": f"No file extension: {filename}"}

        safe_ext = file_extension
        temp_local_path = os.path.join(tempfile.gettempdir(), f"event_{file_id}{safe_ext}")

        blob.download_to_filename(temp_local_path)
        print(f"⬇️ Downloaded: {temp_local_path}")

        # 분석 실행 (파싱한 이름 전달)
        print(f"🚀 분석 시작: User={user_id}, Partner={partner_name}, Type={safe_ext}")
        result = await process_core_logic(temp_local_path, user_id, partner_name, None)

        # 5. 결과 저장
        date_str = extract_date_from_filename(filename)
        datetime_str = extract_datetime_from_filename(filename)  # "2026-02-10 10:30:02" 형식
        result_type = result.get('type', 'unknown')

        if result_type == 'sms':
            # 분석된 전체 메시지 리스트 가져오기
            all_messages = result.get('results', [])

            # 1. 특수 기능 실행 (일정 등록, 피싱 알림 등 사이드 이펙트 처리)
            save_sms_by_category(user_id, all_messages)

            # 2. 전체 메시지를 하나씩 풀어서 개별 저장
            print(f"📨 [SMS 저장] 총 {len(all_messages)}건 개별 저장 시작")

            for msg in all_messages:
                # 원본 데이터 보존을 위해 msg 객체 그대로 저장
                msg["media_type"] = "sms"

                # Firestore 'logs' 배열에 이 객체 하나를 독립적으로 추가 (ArrayUnion)
                save_analysis_to_firestore(user_id, msg, date_str)

        else:
            # 통화 녹음 등은 기존 방식 유지 + 파일명에서 추출한 timestamp 추가
            if datetime_str:
                result["timestamp"] = datetime_str
            save_analysis_to_firestore(user_id, result, date_str)

        # 6. 잠금 해제 (성공)
        if processed_ref:
            processed_ref.update({"status": "success"})
            print(f"[Unlock] 분석 완료: {filename}")

        return {"status": "success"}

    except Exception as e:
        error_msg = str(e)
        print(f"[Error] 분석 실패: {e}")
        import traceback; traceback.print_exc()

        if processed_ref:
            processed_ref.update({"status": "failed", "error": error_msg})
            print(f"[Unlock] 실패 기록")

        if "404" in error_msg or "No such object" in error_msg:
            return {"status": "skipped", "message": "File missing"}

        return {"status": "error", "message": error_msg}

    finally:
        if temp_local_path and os.path.exists(temp_local_path):
            os.remove(temp_local_path)

if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run(app, host="0.0.0.0", port=port)
