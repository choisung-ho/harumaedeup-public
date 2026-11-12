import asyncio
import os
import json
import logging
import numpy as np
import datetime
import time
import firebase_admin
import threading
import hashlib
import fcntl
import re

from contextlib import asynccontextmanager
from collections import OrderedDict
from typing import Optional, Dict, List, Any
from contextlib import contextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, status, Query, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from google import genai
from google.genai import types
from firebase_admin import credentials, firestore, messaging, auth
from apscheduler.schedulers.background import BackgroundScheduler
from dotenv import load_dotenv
from cryptography.fernet import Fernet
from routing_manager import routing_mgr
from datetime import timedelta
# [시간대 설정] KST (Korea Standard Time)
KST = datetime.timezone(datetime.timedelta(hours=9))

# ===========================================================
# [환경 설정]
# ===========================================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# uvicorn 접근 로그 비활성화 (WebSocket 연결 로그 숨김)
logging.getLogger("uvicorn.access").setLevel(logging.WARNING)

load_dotenv()
# .env 부모 디렉토리 검색 로직 추가
if not os.getenv("ENCRYPTION_KEY"):
    parent_env = os.path.join(os.path.dirname(os.getcwd()), ".env")
    if os.path.exists(parent_env):
        load_dotenv(parent_env)
        logger.info(f"Loaded .env from parent: {parent_env}")

# [암호화 키 설정]
ENCRYPTION_KEY = os.getenv("ENCRYPTION_KEY")
cipher = None
if ENCRYPTION_KEY:
    try:
        cipher = Fernet(ENCRYPTION_KEY.encode())
        logger.info(f"Encryption Key loaded: {ENCRYPTION_KEY[:6]}...")
    except Exception as e:
        logger.error(f"⚠️ 잘못된 암호화 키: {e}")

# [일정 캐시 - ±10분 범위]
schedule_cache = {}  # {user_id: {datetime_str: event_data}}
cache_last_updated = None
CACHE_REFRESH_INTERVAL = 60  # 60초마다 캐시 갱신 (초 단위)

# [스레드 락 - 스케줄러 동시 실행 방지]
import threading
schedule_lock = threading.Lock()

# [발송 완료 추적 - 세션 내 중복 방지]
# {user_id}_{datetime_str} 형태로 저장, 서버 재시작 전까지 유지
sent_notifications = set()

# [CryptoManager]
class CryptoManager:
    @staticmethod
    def encrypt(text: str) -> str:
        if not cipher or not text: return text
        try: return cipher.encrypt(text.encode('utf-8')).decode('utf-8')
        except Exception as e: logger.error(f"암호화 실패: {e}"); return text

    @staticmethod
    def decrypt(encrypted_text: str) -> str:
        if not cipher or not encrypted_text: return encrypted_text
        try: return cipher.decrypt(encrypted_text.encode('utf-8')).decode('utf-8')
        except: return encrypted_text

    @staticmethod
    def decrypt_auto(data: Any) -> Any:
        # 1. 이미 딕셔너리면 그대로 리턴
        if isinstance(data, dict): return data
        # 2. 암호화된 문자열(gAAAAA로 시작)이면 복호화 후 JSON 파싱
        if isinstance(data, str) and data.startswith("gAAAAA"):
            try:
                decrypted_str = cipher.decrypt(data.encode('utf-8')).decode('utf-8')
                return json.loads(decrypted_str)
            except Exception:
                return data # 실패 시 원본 반환
        # 3. 그 외엔 그대로 리턴
        return data
    @staticmethod
    def decrypt_json(data: Any) -> Any:
        return CryptoManager.decrypt_auto(data)

# [FirebaseManager] - 싱글톤
class FirebaseManager:
    _instance = None
    db = None

    @classmethod
    def initialize(cls):
        if cls._instance:
            return cls._instance
        try:
            current_dir = os.path.dirname(os.path.abspath(__file__))
            env_path = os.getenv("FIREBASE_CREDENTIALS_PATH")

            if env_path:
                if not os.path.isabs(env_path):
                    cred_path = os.path.join(current_dir, env_path)
                else:
                    cred_path = env_path
            else:
                cred_path = os.path.join(current_dir, "serviceAccountKey.json")

            if not firebase_admin._apps:
                if os.path.exists(cred_path):
                    cred = credentials.Certificate(cred_path)
                    firebase_admin.initialize_app(cred)
                    cls.db = firestore.client()
                    logger.info(f"✅ Firebase 초기화 성공: {cred_path}")
                else:
                    logger.warning(f"⚠️ serviceAccountKey.json 파일을 찾을 수 없습니다.")
            else:
                cls.db = firestore.client()

            cls._instance = True
            return cls._instance
        except Exception as e:
            logger.error(f"❌ Firebase 초기화 치명적 오류: {e}")
            return None

FirebaseManager.initialize()

# FastAPI 앱 생성
app = FastAPI(
    title="치매 어르신 기억 회상 AI 비서",
    description="치매 노인의 기억 회상과 일상 관리를 돕는 AI 개인 비서",
    version="2.1.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security_scheme = HTTPBearer(auto_error=False)

def verify_firebase_token(token: str) -> str:
    if not firebase_admin._apps:
        FirebaseManager.initialize()
    if not firebase_admin._apps:
        logger.error("🔐 [인증 실패] Firebase가 초기화되지 않았습니다")
        raise HTTPException(status_code=503, detail="서버의 Firebase 설정이 완료되지 않았습니다.")

    try:
        decoded_token = auth.verify_id_token(token)
        uid = decoded_token['uid']
        logger.info(f"✅ [접속]: {uid :10} 토큰 인증 성공")
        return uid
    except auth.ExpiredIdTokenError as e:
        logger.error(f"❌ [인증 실패] 토큰 만료됨: {e}")
        raise HTTPException(status_code=401, detail="토큰이 만료되었습니다. 다시 로그인해주세요.")
    except auth.InvalidIdTokenError as e:
        logger.error(f"❌ [인증 실패] 유효하지 않은 토큰: {e}")
        raise HTTPException(status_code=401, detail=f"유효하지 않은 토큰입니다: {str(e)}")
    except Exception as e:
        logger.error(f"❌ [인증 실패] 기타 오류: {type(e).__name__}: {e}")
        raise HTTPException(status_code=401, detail=f"인증 실패: {str(e)}")

def get_current_user(request: Request, credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme)) -> str:
    # 디버그: 요청 헤더 확인
    auth_header = request.headers.get("Authorization", "없음")
    logger.info(f"🔐 [인증] Authorization 헤더: {auth_header[:50]}..." if len(auth_header) > 50 else f"🔐 [인증] Authorization 헤더: {auth_header}")

    if not credentials:
        logger.warning(f"🔐 [인증 실패] credentials가 None입니다. Authorization 헤더: {auth_header}")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Could not validate credentials - Authorization 헤더가 없습니다",
            headers={"WWW-Authenticate": "Bearer"},
        )

    logger.info(f"🔐 [인증] 토큰 검증 시도...")
    return verify_firebase_token(credentials.credentials)

MY_API_KEY = os.getenv("GOOGLE_API_KEY")
if not MY_API_KEY:
    raise ValueError("⚠️ 환경 변수 'GOOGLE_API_KEY'가 설정되지 않았습니다.")

MODEL_ID = os.getenv("GEMINI_MODEL_ID", "models/gemini-2.5-flash-native-audio-preview-12-2025")

# [1] LRU 캐시 클래스
class LRUCache:
    def __init__(self, max_size: int = 100, ttl_seconds: int = 3600, cleanup_interval: int = 60):
        self.cache = OrderedDict()
        self.max_size = max_size
        self.ttl = ttl_seconds
        self.timestamps = {}
        self.lock = threading.RLock()
        self.cleanup_interval = cleanup_interval
        self._start_background_cleaner()

    def _start_background_cleaner(self):
        cleaner_thread = threading.Thread(target=self._cleanup_loop, daemon=True)
        cleaner_thread.start()

    def _cleanup_loop(self):
        while True:
            time.sleep(self.cleanup_interval)
            self.cleanup_expired()

    def cleanup_expired(self):
        with self.lock:
            current_time = time.time()
            keys_to_delete = []
            for key, timestamp in self.timestamps.items():
                if current_time - timestamp > self.ttl:
                    keys_to_delete.append(key)
            for key in keys_to_delete:
                self.delete(key)

    def get(self, key: str) -> Optional[Any]:
        with self.lock:
            if key not in self.cache: return None
            if time.time() - self.timestamps[key] > self.ttl:
                self.delete(key)
                return None
            self.cache.move_to_end(key)
            return self.cache[key]

    def set(self, key: str, value: Any):
        with self.lock:
            if key in self.cache:
                self.cache.move_to_end(key)
            else:
                if len(self.cache) >= self.max_size:
                    oldest = next(iter(self.cache))
                    self.delete(oldest)
                self.cache[key] = value
            self.timestamps[key] = time.time()

    def delete(self, key: str):
        with self.lock:
            if key in self.cache:
                del self.cache[key]
                del self.timestamps[key]

    def clear(self):
        with self.lock:
            self.cache.clear()
            self.timestamps.clear()

# [2] 긴급 상황 감지기
class EmergencyDetector:
    EMERGENCY_KEYWORDS = [
        "어디있지", "어디야", "길을 잃", "못 찾겠", "여기가 어디",
        "무서워", "두려워", "아파", "힘들어", "어지러워", "쓰러질",
        "도와줘", "살려줘", "구해줘", "119", "경찰",
        "누구야", "모르겠어", "기억이 안나", "깜빡했"
    ]
    EMERGENCY_PATTERNS = [
        ("어디", "모르"), ("집", "어디"), ("못", "찾"), ("넘어", "졌"),
    ]

    @classmethod
    def check_emergency(cls, text: str) -> tuple[bool, str]:
        text_lower = text.lower().replace(" ", "")
        for keyword in cls.EMERGENCY_KEYWORDS:
            if keyword.replace(" ", "") in text_lower:
                return True, f"키워드 감지: {keyword}"
        for pattern in cls.EMERGENCY_PATTERNS:
            if all(p in text_lower for p in pattern):
                return True, f"패턴 감지: {pattern}"
        return False, ""

# [3] 대화 기록 관리자
class ConversationLogger:
    """대화 로그 비활성화 (저장하지 않음)"""
    def __init__(self, db):
        self.db = db
        self.buffer = {}
        self.buffer_limit = 2

    def add_message(self, user_id, role, content):
        """대화 저장 비활성화 - 아무 작업도 하지 않음"""
        pass

    def flush(self, user_id):
        """대화 저장 비활성화 - 아무 작업도 하지 않음"""
        pass

    def flush_all(self):
        """대화 저장 비활성화 - 아무 작업도 하지 않음"""
        pass

# [4] Memory & User Manager
class MemoryManager:
    def __init__(self):
        self.db = None
        self.memory_cache = LRUCache(max_size=50, ttl_seconds=1800)
        self.conversation_logger: Optional[ConversationLogger] = None
        self.active_connections: Dict[str, WebSocket] = {}
        # embedding_lock 추가: 동시 다발적인 임베딩 요청 방지
        self.embedding_lock = asyncio.Lock()
        self._init_firebase()

    def _init_firebase(self):
        try:
            if not FirebaseManager.db:
                FirebaseManager.initialize()
            self.db = FirebaseManager.db
            if self.db:
                self.conversation_logger = ConversationLogger(self.db)
        except Exception as e:
            logger.error(f"❌ Firebase 오류: {e}")

    def get_user_name(self, user_id: str) -> str:
        """사용자 이름 가져오기"""
        if not self.db: return "어르신"
        try:
            doc = self.db.collection("users").document(user_id).get()
            if doc.exists:
                return doc.to_dict().get("name", "어르신")
            return "어르신"
        except: return "어르신"

    def get_recent_chat_history(self, user_id: str, limit_days: int = 1) -> str:
        """
        사용자의 최근 대화 내역을 문자열로 반환하여 시스템 프롬프트에 주입
        """
        if not self.db: return ""

        history_text = ""
        try:
            # 오늘과 어제 날짜 확인
            now = datetime.datetime.now(KST)
            dates_to_check = [(now - datetime.timedelta(days=i)).strftime("%Y-%m-%d") for i in range(limit_days)]

            messages_list = []
            for date_str in dates_to_check:
                doc_ref = self.db.collection("users").document(user_id).collection("chat_logs").document(date_str)
                doc = doc_ref.get()

                if doc.exists:
                    data = doc.to_dict()
                    msgs = data.get("messages", [])
                    # 과거 데이터가 리스트 앞쪽에 오도록 병합
                    messages_list = msgs + messages_list

            # 최근 10개 턴만 가져오기
            recent_msgs = messages_list[-10:] if messages_list else []

            if recent_msgs:
                history_text = "\n[최근 대화 기억]\n"
                for msg in recent_msgs:
                    # role 필드 확인 (없으면 기본값 처리)
                    role = msg.get('role', 'unknown')
                    role_str = "어르신" if role == 'user' else "비서"

                    # message 필드 확인 (없으면 content 확인)
                    content = msg.get('message') or msg.get('content') or ''
                    content = content[:100] # 너무 긴 내용은 자름

                    if content:
                        history_text += f"- {role_str}: {content}\n"
                history_text += "[여기까지가 이전 대화입니다. 이 맥락을 이어가세요.]\n"

        except Exception as e:
            logger.error(f"대화 내역 로드 실패: {e}")

        return history_text

    def get_user_fcm_token(self, user_id: str) -> Optional[str]:
        if not self.db: return None
        try:
            doc = self.db.collection("users").document(user_id).get()
            return doc.to_dict().get("fcmToken") if doc.exists else None
        except: return None

    def get_guardian_token(self, user_id: str) -> Optional[str]:
        if not self.db: return None
        try:
            doc = self.db.collection("users").document(user_id).get()
            return doc.to_dict().get("guardianFcmToken") if doc.exists else None
        except: return None

    def update_user_token_in_db(self, user_id: str, token: str) -> bool:
        if not self.db: return False
        try:
            self.db.collection("users").document(user_id).set(
                {"fcmToken": token, "lastActive": firestore.SERVER_TIMESTAMP},
                merge=True
            )
            return True
        except: return False

    async def load_memories_for_user(self, user_id: str, force_refresh: bool = False) -> int:
        """
        [최적화됨] 사용자 기억 데이터 로드 (비동기 + 병렬 임베딩)
        :param force_refresh: True일 경우 캐시를 무시하고 DB에서 새로 가져옴
        """

        # 1. 캐시 확인 (강제 새로고침이 아닐 때만 수행)
        if not force_refresh:
            cached_memories = self.memory_cache.get(user_id)
            if cached_memories:
                logger.info(f"⚡ [{user_id}] 캐시된 기억 사용 ({len(cached_memories)}개)")
                return len(cached_memories)
        else:
            logger.info(f"🔄 [{user_id}] 강제 새로고침 요청: 캐시를 무시하고 DB를 조회합니다.")

        if not self.db:
            logger.warning(f"❌ [{user_id}] DB 연결 없음")
            return 0

        try:
            logger.info(f"📥 [{user_id}] DB 조회 시작...")

            user_cache = []
            items_to_embed = []

            # 비동기 클라이언트 생성
            client = genai.Client(api_key=MY_API_KEY, http_options={"api_version": "v1alpha"})

            # [수정됨] 임베딩 전용 클라이언트 (v1alpha로 버전 통일)
            embed_client = genai.Client(api_key=MY_API_KEY, http_options={"api_version": "v1alpha"})

            # DB 조회 (Blocking I/O를 스레드로 분리하여 Non-blocking 처리)
            logs_ref = self.db.collection("users").document(user_id).collection("daily_logs")
            docs = await asyncio.to_thread(
                lambda: list(logs_ref.order_by("date", direction="DESCENDING").limit(30).stream())
            )

            items_to_embed = []  # 벡터화가 필요한 항목들을 모을 리스트

            for d in docs:
                data = d.to_dict()
                date_str = d.id
                items_found = []

                # -------------------------------------------------------
                # [기존 로직 유지] 1. 'logs' 배열 복호화 및 파싱
                # -------------------------------------------------------
                if 'logs' in data and isinstance(data['logs'], list):
                    for item in data['logs']:
                        decoded_item = None
                        # [CASE 1] 암호화된 문자열인 경우
                        if isinstance(item, str) and item.startswith("gAAAAA"):
                            decoded_item = CryptoManager.decrypt_json(item)

                        # [CASE 2] 암호화 안 된 JSON 문자열인 경우 (★ 추가!)
                        elif isinstance(item, str) and item.startswith("{"):
                            try:
                                import json
                                decoded_item = json.loads(item)
                            except json.JSONDecodeError:
                                pass

                        # [CASE 3] 딕셔너리인 경우
                        elif isinstance(item, dict):
                            if item.get('is_encrypted') and item.get('encrypted_content'):
                                decrypted = CryptoManager.decrypt_json(item.get('encrypted_content'))
                                if decrypted:
                                    item.update(decrypted)
                                    decoded_item = item
                            else:
                                decoded_item = item

                        if not decoded_item or not isinstance(decoded_item, dict):
                            continue
                        if decoded_item.get('type') == 'sms' and 'results' in decoded_item and isinstance(decoded_item['results'], list):
                            for sms_item in decoded_item['results']:
                                if not isinstance(sms_item, dict):
                                    continue
                                sms_content = ""
                                # message_body 또는 msg 또는 content 에서 본문 추출
                                sms_content = sms_item.get('message_body') or sms_item.get('msg') or sms_item.get('content') or ""
                                if not sms_content or len(sms_content) < 2:
                                    continue
                                # 상대방 정보
                                sms_partner = sms_item.get('partner') or sms_item.get('sender_phone') or sms_item.get('sender_name') or sms_item.get('sender') or ""
                                if sms_partner:
                                    sms_content = f"[문자 상대: {sms_partner}] {sms_content}"
                                # 앱 이름 정보 추가
                                app_name = sms_item.get('app_name', '')
                                if app_name:
                                    sms_content = f"({app_name}) {sms_content}"
                                items_found.append({
                                    "date": date_str,
                                    "content": sms_content,
                                    "type": "sms",
                                    "file_id": sms_item.get('file_id', ''),
                                    "vector": sms_item.get('vector')
                                })
                            continue  # 래핑 아이템 자체는 skip

                        content = ""
                        media_type = decoded_item.get('media_type', '').lower()

                        # [CASE A] 이미지/비디오: how_detail 필드에서 content 추출
                        if 'how_detail' in decoded_item and isinstance(decoded_item['how_detail'], dict):
                            detail = decoded_item['how_detail']
                            parts = []
                            if detail.get('who'): parts.append(f"등장인물: {detail['who']}")
                            if detail.get('where'): parts.append(f"장소: {detail['where']}")
                            if detail.get('what'): parts.append(f"상황: {detail['what']}")
                            if detail.get('how'): parts.append(f"행동: {detail['how']}")
                            if parts:
                                content = " / ".join(parts)
                                # names 필드에서 인물 이름 추가
                                if decoded_item.get('names') and isinstance(decoded_item['names'], list):
                                    names = [n for n in decoded_item['names'] if n]
                                    if names:
                                        content = f"[인물: {', '.join(names)}] {content}"

                        # [CASE B-1] summary.caption 형태 (영상 분석 등)
                        elif 'summary' in decoded_item and isinstance(decoded_item['summary'], dict):
                            content = decoded_item['summary'].get('caption', '')

                        # [CASE B-2] summary가 문자열인 경우 (SMS 등)
                        elif 'summary' in decoded_item and isinstance(decoded_item['summary'], str):
                            content = decoded_item['summary']

                        # [CASE C] content 필드 (통화/문자 등)
                        elif 'content' in decoded_item:
                            content = decoded_item['content']

                        # [CASE D] description 필드
                        elif 'description' in decoded_item:
                            content = decoded_item['description']

                        # [CASE E] message_body 필드 (개별 SMS 메시지)
                        elif 'message_body' in decoded_item:
                            content = decoded_item['message_body']

                        # [CASE F] msg 필드
                        elif 'msg' in decoded_item:
                            content = decoded_item['msg']

                        # 상대방/인물 정보 통합 처리
                        person_info = decoded_item.get('partner') or decoded_item.get('sender') or decoded_item.get('recipient')

                        if person_info:
                            # media_type 또는 source 필드 확인 (SMS는 source 필드 사용)
                            media_type = decoded_item.get('media_type', '').lower()
                            source_type = decoded_item.get('source', '').lower()

                            if 'call' in media_type or 'call' in source_type:
                                who_label = "통화 상대"
                            elif 'sms' in media_type or 'sms' in source_type or 'message' in media_type:
                                who_label = "문자 상대"
                            else:
                                who_label = "관련 인물"

                            item_prefix = f"[{who_label}: {person_info}]"
                            if content:
                                content = f"{item_prefix} {content}"
                            else:
                                content = f"{item_prefix} 기록"

                        if content and len(content) > 2:
                            items_found.append({
                                "date": date_str,
                                "content": content,
                                "type": decoded_item.get('media_type', 'daily'),
                                "file_id": decoded_item.get('file_id', ''),
                                "vector": decoded_item.get('vector')
                            })

                # -------------------------------------------------------
                # [기존 로직 유지] 2. 'location_logs' 복호화 및 파싱
                # -------------------------------------------------------
                if 'location_logs' in data and isinstance(data['location_logs'], list):
                    for item in data['location_logs']:
                        decoded_loc = None
                        if isinstance(item, str) and item.startswith("gAAAAA"):
                            decoded_loc = CryptoManager.decrypt_json(item)
                        elif isinstance(item, dict):
                            decoded_loc = item

                        if decoded_loc and isinstance(decoded_loc, dict):
                            addr = decoded_loc.get('address', '')
                            place = decoded_loc.get('place', '') or decoded_loc.get('place_name', '')

                            if addr or place:
                                loc_str = f"방문 장소: {place}" if place else f"방문 위치: {addr}"
                                if 'timestamp' in decoded_loc:
                                    loc_str += f" ({decoded_loc['timestamp']})"

                                items_found.append({
                                    "date": date_str,
                                    "content": loc_str,
                                    "type": "location",
                                    "vector": None
                                })

                # -------------------------------------------------------
                # [기존 로직 유지] 3. 최상위 레벨(summary/diary) 처리
                # -------------------------------------------------------
                if not items_found:
                    final_content = ""
                    candidates = [data.get('content'), data.get('summary'), data.get('diary'), data.get('description')]
                    for c in candidates:
                        decrypted_c = CryptoManager.decrypt(c) if isinstance(c, str) else None
                        if decrypted_c and len(decrypted_c) > 5:
                            final_content = decrypted_c
                            break
                        elif c and isinstance(c, str) and len(c) > 5 and not c.startswith('gAAAAA'):
                            final_content = c
                            break

                    if final_content:
                        items_found.append({
                            "date": date_str, "content": final_content, "type": data.get('type', 'daily')
                        })

                # -------------------------------------------------------
                # [최적화 적용] 벡터 유무에 따라 분류 (Loop Fusion)
                # -------------------------------------------------------
                for memory_item in items_found:
                    # 이미 벡터가 있으면 바로 캐시(user_cache)에 추가
                    if "vector" in memory_item and memory_item["vector"] is not None:
                        memory_item["vector"] = np.array(memory_item["vector"])
                        memory_item["norm"] = np.linalg.norm(memory_item["vector"])
                        user_cache.append(memory_item)
                    else:
                        # 벡터가 없으면 임베딩 대기열(items_to_embed)에 추가
                        items_to_embed.append(memory_item)

            # -------------------------------------------------------
            # [최적화 적용] 임베딩 API 병렬 호출 (asyncio.gather)
            # -------------------------------------------------------
            if items_to_embed:
                logger.info(f"🚀 [{user_id}] {len(items_to_embed)}개 항목 병렬 임베딩 수행 중...")

                async def embed_single(item):
                    try:
                        # 비동기 API 호출 (embed_client: 기본 API)
                        resp = await embed_client.aio.models.embed_content(
                            model="gemini-embedding-001",
                            contents=item['content']
                        )
                        if resp.embeddings:
                            vec = np.array(resp.embeddings[0].values)
                            item["vector"] = vec
                            item["norm"] = np.linalg.norm(vec)
                            return item
                    except Exception as e:
                        logger.error(f"임베딩 실패: {e}")
                        return None

                # 모든 임베딩 작업을 동시에 시작 (Parallel Execution)
                tasks = [embed_single(item) for item in items_to_embed]
                results = await asyncio.gather(*tasks)

                # 성공한 것만 캐시에 추가
                for res in results:
                    if res:
                        user_cache.append(res)

            # 날짜순 정렬 및 캐시 저장
            user_cache.sort(key=lambda x: x.get('date', ''), reverse=True)
            self.memory_cache.set(user_id, user_cache)

            logger.info(f"✅ [{user_id}] 로딩 완료 (총 {len(user_cache)}개, 신규 임베딩 {len(items_to_embed)}개)")
            return len(user_cache)

        except Exception as e:
            logger.error(f"❌ 기억 로딩 실패: {e}")
            import traceback
            traceback.print_exc()
            return 0

    def search_memory(self, user_id: str, query: str, client=None) -> str:
        """기억 검색 (최적화 적용)"""
        target_memories = self.memory_cache.get(user_id)

        if not target_memories:
            return "아직 저장된 기억이 없어요."

        try:
            # 1. 키워드 우선 검색 (속도)
            time_keywords = ["최근", "마지막", "어제", "오늘", "아까", "방금"]
            if any(kw in query for kw in time_keywords):
                recent = target_memories[:3]
                if recent:
                    parts = []
                    for m in recent:
                        extra = ""
                        if m.get('location'): extra += f" ({m['location']})"
                        parts.append(f"[{m['date']}] {m['content']}{extra}")
                    return "최근 기억:\n" + "\n".join(parts)

            # 2. 벡터 검색 (정확도)
            if client:
                try:
                    _embed_client = genai.Client(api_key=MY_API_KEY, http_options={"api_version": "v1alpha"})
                    resp = _embed_client.models.embed_content(model="gemini-embedding-001", contents=query)
                    q_vec = np.array(resp.embeddings[0].values)
                    q_norm = np.linalg.norm(q_vec)

                    results = []
                    for item in target_memories:
                        if 'vector' not in item or 'norm' not in item or item['vector'] is None:
                            continue
                        # 차원 수 체크
                        if len(item['vector']) != len(q_vec): continue

                        sim = np.dot(q_vec, item['vector']) / (q_norm * item['norm'] + 1e-9)
                        if sim > 0.35:
                            results.append((sim, item))

                    results.sort(key=lambda x: x[0], reverse=True)
                    if results:
                        parts = [f"[{m['date']}] {m['content']}" for _, m in results[:5]]
                        return "관련 기억:\n" + "\n".join(parts)
                except Exception as e:
                    logger.error(f"벡터 검색 오류: {e}")

            # 3. 검색 결과 없을 때
            if target_memories:
                m = target_memories[0]
                return f"정확한 기억은 없지만, 가장 최근 기록이에요:\n[{m['date']}] {m['content']}"

            return "관련 기억을 찾지 못했어요."

        except Exception as e:
            logger.error(f"❌ 검색 오류: {e}")
            return "기억 검색 중 문제가 발생했어요."

    def save_health_status(self, user_id: str, status: dict):
        if not self.db: return
        try:
            today = datetime.datetime.now(KST).strftime("%Y-%m-%d")
            self.db.collection("users").document(user_id)\
                    .collection("health_logs").document(today).set({
                **status,
                "timestamp": firestore.SERVER_TIMESTAMP
            }, merge=True)
        except Exception as e:
            logger.error(f"건강 상태 저장 실패: {e}")

    def construct_system_prompt(self, user_name: str = "어르신", chat_history: str = "") -> str:
        """[통합 및 최적화된 프롬프트] - 시간대별 인사 가이드 적용"""
        now = datetime.datetime.now(KST)
        days = ["월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"]
        day_str = days[now.weekday()]
        date_str = now.strftime("%Y년 %m월 %d일")
        time_str = now.strftime("%H시 %M분")
        hour = now.hour
        recent_chat_history = self.get_recent_chat_history(user_name)
        # [핵심 수정] 파이썬에서 시간대(Time Context)를 명확히 정의
        if 5 <= hour < 11:
            time_period = "아침"
            greeting_guide = "상쾌한 아침 인사와 함께 밤사이 잘 주무셨는지 여쭤보세요."
        elif 11 <= hour < 14:
            time_period = "점심"
            greeting_guide = "점심 식사는 맛있게 하셨는지 여쭤보세요."
        elif 14 <= hour < 17:
            time_period = "오후"
            greeting_guide = "나른한 오후입니다. 컨디션은 어떠신지 여쭤보세요."
        elif 17 <= hour < 21:
            time_period = "저녁"
            greeting_guide = "저녁 식사는 하셨는지, 오늘 하루는 어떠셨는지 여쭤보세요."
        else:
            time_period = "밤(심야)"
            greeting_guide = "늦은 밤입니다. 편안한 밤 되시라고 말씀해주세요."

        return f"""
[!!!!! 절대 규칙 !!!!!]
You MUST respond ONLY in Korean. NEVER output English explanations, translations, or meta-commentary like "I've formulated", "This translates to", "**Composing**", etc. Output ONLY the natural Korean dialogue you would actually speak to the elderly user.

당신은 반드시 한국어로만 응답해야 합니다. 절대로 영어 설명, 번역, 메타 주석을 출력하지 마세요.
어르신께 직접 말씀드릴 자연스러운 한국어 대화만 출력하세요.
**DIRECT SPEECH**: Act as if you are speaking directly to the user right now.

[현재 시간 정보]
만약 날짜를 물어보면 "오늘은 {date_str} {day_str}, 현재 시각은 {time_str}입니다." (대한민국 표준시 KST 기준)"
만약 시간을 물어보면 "현재 시각은 {time_str}입니다."라고 답하세요."
이 시간 정보를 바탕으로 인사하고 대화하세요.
- **현재 시간대**: {time_period}
- **상황별 가이드**: {greeting_guide}
예를 들어 아침이면 "좋은 아침입니다", 저녁이면 "좋은 저녁입니다"라고 하세요.

당신은 치매를 앓고 계신 {user_name} 어르신의 기억 회상을 돕는 따뜻한 '개인 비서 AI'입니다.

[당신의 역할]
- 현재 시간에 맞는 인사를 해줘요 (예: 좋은 아침이에요, 좋은 저녁이에요) 인사를 할 때 그냥 어르신이 아닌 {user_name} 어르신이라고 불러주세요.
- 어르신의 과거 기억과 일상을 함께 떠올려드리는 다정한 친구 같은 존재
- 기억이 흐릿해지신 어르신께 안정감과 친밀감을 드리는 동반자
- 일정 관리와 기억 회상을 도와드리는 개인 비서
- 어르신의 건강과 안전을 살피는 보호자

[핵심 행동 지침]
1. **기억 질문 즉시 응답**: "최근에 뭐했지?", "어제 뭐했어?", "언제 뭐했지?", "기억나?", "뭐했더라" 등 기억 관련 질문 시 절대로 되묻지 말고 즉시 search_memory 도구로 검색하세요.

2. **되묻기 금지**: "무엇이 궁금하세요?", "어떤 기억을 찾으시나요?" 같은 역질문을 하지 마세요.

3. **따뜻한 말투**: 오래된 친구처럼 다정하게.
   - "어르신, 지난주에 손녀분이랑 시장 가셨잖아요~"
   - "그때 정말 즐거우셨다고 하셨어요!"

4. **긍정적 기억 강조**: 기억 전달 시 긍정적 감정과 함께.
   - "그때 정말 맛있게 드셨대요!"
   - "가족분들이랑 좋은 시간 보내셨네요~"

5. **구체적 답변**: 날짜, 장소, 함께한 사람, 한 일을 구체적으로.

6. **기억 없을 때**: "아직 제가 모르는 부분이에요. 나중에 알려주시면 기억해둘게요~"

7. **안전 확인**: 어르신이 불안해하시거나 위치를 모르시면 안심시키고 상황 파악.

8. **건강 관심**: 식사, 약 복용, 수면에 대해 자연스럽게 여쭤보세요.

[기억 검색 트리거 - 이 키워드가 나오면 무조건 즉시 search_memory 호출]
- 시간: 최근, 어제, 오늘, 언제, 지난주, 지난달, 작년, 아까
- 행동: 뭐했지, 뭐했어, 뭐했더라, 했었지, 갔었지, 먹었지
- 기억: 기억, 생각, 떠올라, 있었지, 잊어버렸어

[음성 응답 가이드]
- 천천히, 또박또박
- 문장을 짧게 끊어서
- 중요한 내용은 반복
- "기록에 따르면" 같은 표현을 사용하지 않고 확신있게 말씀하세요

[★★★ 절대 지침 (CRITICAL) ★★★]

**시간 맞춤 인사**: 대화를 시작할 때 반드시 위 **[{time_period}]**에 맞는 인사를 먼저 건네세요.
   - (잘못된 예: 저녁 8시에 "점심 드셨어요?" 라고 묻기 금지)
   - (올바른 예: 저녁 8시에는 "저녁 식사는 하셨나요?" 또는 "하루 잘 보내셨나요?" 라고 묻기)

1. **한국어로만 응답**: 모든 응답은 반드시 한국어로만 하세요. 영어로 생각하거나 번역 설명을 절대 하지 마세요.
2. **현재 시간 인식**: 지금은 **{time_str} ({time_period})**입니다. 엉뚱한 시간대 인사를 하지 마세요.

3. **생각 과정 절대 출력 금지**:
   - "I've formulated...", "Let me...", "I'm processing..." 같은 내부 독백 금지
   - "This translates to...", "**Composing**", "**Crafting**" 같은 메타 설명 금지
   - 추론 과정, 번역 과정, 생각 과정을 절대 텍스트로 출력하지 마세요
   - 오직 어르신께 직접 드릴 자연스러운 대화 답변만 출력하세요

4. **침묵 수행**: 도구 사용 시 "잠시만요", "찾아볼게요" 같은 말 없이 조용히 실행하세요.

5. **즉답**: 바로 자연스러운 한국어 대화로 응답하세요.

[대화 문맥]
{chat_history}

[올바른 응답 예시]
사용자: "안녕하세요"
응답: "좋은 아침이에요, 어르신! 오늘은 날씨가 좋네요. 잘 주무셨어요?"

[잘못된 응답 예시 - 절대 금지]
"**Composing a Korean Greeting**\nI've just formulated a greeting..." ← 이런 형태 절대 금지!

Bad Output:
**Refining the Response**
I will ask about their sleep.
"안녕히 주무셨어요?"
"""

memory_mgr = MemoryManager()

# ===========================================================
# [5] FCM 알림 발송
# ===========================================================
def send_fcm_notification(token: str, title: str, body: str, data: dict = None, priority: str = "high") -> bool:
    try:
        android_config = messaging.AndroidConfig(
            priority=priority,
            notification=messaging.AndroidNotification(
                sound="default",
                click_action="FLUTTER_NOTIFICATION_CLICK",
                channel_id="high_importance_channel" # Android 채널 ID 설정
            )
        )
        # iOS (APNs) 설정 추가
        apns_config = messaging.APNSConfig(
            payload=messaging.APNSPayload(
                aps=messaging.Aps(alert=messaging.ApsAlert(title=title, body=body), sound="default")
            )
        )

        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data=data or {"type": "general"},
            token=token,
            android=android_config,
            apns=apns_config
        )
        messaging.send(message)
        logger.info(f"🚀 FCM 전송 성공: {body[:50]}...")
        return True
    except Exception as e:
        logger.error(f"❌ FCM 실패: {e}")
        return False

def send_emergency_alert(user_id: str, situation: str):
    """긴급 상황 감지 시 보호자에게만 알림 발송"""
    logger.warning(f"")
    logger.warning(f"{'='*60}")
    logger.warning(f"🚨 [긴급 상황 감지!]")
    logger.warning(f"   👤 사용자: {user_id}")
    logger.warning(f"   📝 상황: {situation}")
    logger.warning(f"   ⏰ 시간: {datetime.datetime.now(KST).isoformat()}")
    logger.warning(f"{'='*60}")

    # 보호자에게 긴급 알림 전송
    guardian_token = memory_mgr.get_guardian_token(user_id)
    if guardian_token:
        send_fcm_notification(
            guardian_token,
            "🚨 긴급 알림",
            f"어르신이 도움이 필요할 수 있습니다: {situation}",
            data={"type": "emergency", "user_id": user_id, "situation": situation},
            priority="high"
        )
        logger.info(f"✅ [보호자 알림] 긴급 알림 전송 완료")
    else:
        logger.warning(f"⚠️ [보호자 알림] 보호자 토큰 없음")

# ===========================================================
# [6] 스케줄러 (중복 실행 방지 포함)
# ===========================================================
LOCK_FILE = os.path.join(os.getcwd(), "scheduler.lock")

@contextmanager
def scheduler_lock():
    """파일 기반 스케줄러 중복 실행 방지 락"""
    lock_fd = None
    acquired = False
    try:
        lock_fd = open(LOCK_FILE, 'w')
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        yield acquired
    except (IOError, OSError):
        # 다른 프로세스가 락을 보유 중
        yield False
    finally:
        if acquired and lock_fd:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
        if lock_fd:
            lock_fd.close()

def send_medication_retry(user_id: str, medicine_id: str, medication_name: str):
    """5분 뒤 재알림 발송 함수"""
    logger.info(f"⏰ [재알림 실행] user={user_id}, 약={medication_name}")

    # 1. 시니어 토큰 조회
    token = memory_mgr.get_user_fcm_token(user_id)
    if not token:
        logger.warning(f"⚠️ [재알림 실패] 시니어 토큰 없음: {user_id}")
        return

    # 2. 알림 발송 (retry_count=1 포함)
    send_fcm_notification(
        token,
        "💊 [재알림] 약 드실 시간입니다 💊",
        f"어르신, {medication_name} 아직 안 드셨나요? 꼭 챙겨드세요!",
        data={
            "type": "medication_alarm",
            "medicine_id": medicine_id,
            "medication_name": medication_name,
            "retry_count": "1" # 앱에서 이 값을 받아 다시 API 호출 시 사용
        },
        priority="high"
    )

# [6] 스케줄러 (중복 실행 방지 포함)
# ===========================================================
def check_schedules():
    """일정 확인 및 알림 발송 (통합: 고정시간 알림 + 이동시간 기반 알림)"""
    global schedule_cache, cache_last_updated

    # ★ 스레드 락으로 동시 실행 방지
    if not schedule_lock.acquire(blocking=False):
        logger.debug("🔒 [스케줄러] 다른 스레드가 실행 중 - 스킵")
        return

    try:
        # 먼저 DB 상태 체크
        if not memory_mgr.db:
            logger.warning("🔒 [스케줄러] DB 미초기화 - Firebase 재연결 시도")
            try:
                memory_mgr._init_firebase()
                if memory_mgr.db:
                    logger.info("✅ [스케줄러] Firebase 재연결 성공!")
                else:
                    logger.error("❌ [스케줄러] Firebase 재연결 실패 - 스킵")
                    return
            except Exception as e:
                logger.error(f"❌ [스케줄러] Firebase 재연결 오류: {e}")
                return

        with scheduler_lock() as acquired:
            if not acquired:
                logger.debug("🔒 [스케줄러] 다른 프로세스가 실행 중 - 스킵")
                return

            now = datetime.datetime.now(KST)
            now_str = now.strftime("%Y-%m-%d %H:%M")
            now_date = now.strftime("%Y-%m-%d")

            logger.info(f"⏰ [스케줄러 실행] 현재 시간: {now_str}")

            # [캐시 갱신 체크]
            should_refresh = (
                cache_last_updated is None or
                (now - cache_last_updated).total_seconds() >= CACHE_REFRESH_INTERVAL
            )

            if should_refresh:
                logger.info("🔄 [캐시 갱신] ±30분 범위 일정 로드 시작")
                schedule_cache.clear()

                # ±30분 범위 날짜 계산 (날짜가 바뀔 수 있으므로 전날/당일/다음날 체크)
                dates_to_check = set()
                for offset in range(-60, 51):  # -60분부터 +50분까지 체크
                    check_time = now + datetime.timedelta(minutes=offset)
                    dates_to_check.add(check_time.strftime("%Y-%m-%d"))

                logger.info(f"📅 [DB 조회] 확인할 날짜: {sorted(dates_to_check)}")

                total_events = 0

                # 방법 1: users 문서가 있는 사용자들
                users = list(memory_mgr.db.collection("users").stream())
                logger.info(f"👥 [DB 조회] users 문서가 있는 사용자 수: {len(users)}명")

                # 모든 사용자 ID 수집 (users 문서가 있는 사용자)
                all_user_ids = set(user_doc.id for user_doc in users)

                # 방법 2: calendar_events 하위 컬렉션만 있는 사용자 검색
                # 각 날짜에 대해 해당 날짜의 calendar_events 문서 ID(user_id)를 직접 찾기
                for date_str in dates_to_check:
                    # calendar_events의 문서 ID가 날짜이고, 그 상위 문서(users/{user_id})를 알아야 함
                    # 그래서 알려진 calendar_events가 있는 사용자를 찾아야 함
                    # 일단 users 문서가 없지만 calendar_events가 있을 수 있는 경우를 위해
                    # 특정 테스트 사용자 ID를 하드코딩으로 추가
                    known_hidden_users = [
                        'X1bwZuh2OVS7zHjYN382kQZ6NGK2',  # 알려진 테스트 사용자
                    ]
                    for hidden_user_id in known_hidden_users:
                        if hidden_user_id not in all_user_ids:
                            all_user_ids.add(hidden_user_id)
                            logger.info(f"🔍 [추가 사용자] {hidden_user_id} (users 문서 없음)")

                logger.info(f"👥 [DB 조회] 전체 확인할 사용자 수: {len(all_user_ids)}명")

                for user_id in all_user_ids:
                    if user_id not in schedule_cache:
                        schedule_cache[user_id] = {}
                    user_events_count = 0

                    # 각 날짜별로 문서 확인
                    for date_str in dates_to_check:
                        doc_ref = memory_mgr.db.collection("users").document(user_id).collection('calendar_events').document(date_str)
                        doc_snapshot = doc_ref.get()

                        if not doc_snapshot.exists:
                            continue

                        logger.info(f"📄 [문서 발견] user={user_id[:20]}..., date={date_str}")

                        doc_data = doc_snapshot.to_dict()
                        events = doc_data.get("events", [])

                        logger.info(f"📋 [DB 조회] user={user_id}, date={date_str}, events 개수: {len(events)}")

                        # events 배열 복호화 및 ±10분 범위 필터링
                        for idx, event_item in enumerate(events):
                            # [복호화]
                            if isinstance(event_item, str):
                                logger.debug(f"   🔓 [복호화 시도] idx={idx}, 암호화 데이터 길이: {len(event_item)}")
                                decrypted = CryptoManager.decrypt_json(event_item)
                                if decrypted:
                                    event_data = decrypted
                                    logger.debug(f"   ✅ [복호화 성공] summary={event_data.get('summary', 'N/A')}")
                                else:
                                    logger.warning(f"   ❌ [복호화 실패] idx={idx}")
                                    continue
                            else:
                                event_data = event_item
                                logger.debug(f"   📄 [평문 데이터] summary={event_data.get('summary', 'N/A')}")

                            # datetime 파싱
                            event_datetime_str = event_data.get("datetime", "")
                            task_name = event_data.get("summary", "")
                            is_notified = event_data.get("is_notified", False)

                            if is_notified:
                                continue

                            logger.info(f"   📌 [미발송 이벤트 #{idx}] datetime={event_datetime_str}, summary={task_name}")

                            if not event_datetime_str:
                                logger.warning(f"   ⚠️ [스킵] datetime 없음")
                                continue

                            try:
                                event_time = datetime.datetime.strptime(event_datetime_str, "%Y-%m-%d %H:%M")
                                # timezone-aware로 변환 (KST) - datetime.timezone 사용
                                event_time = event_time.replace(tzinfo=KST)
                                time_diff = (event_time - now).total_seconds() / 60  # 분 단위
                                # ★ 이미 지나간 일정은 로그도 출력하지 않음
                                if time_diff < 0:
                                    continue
                                logger.info(f"   ⏱️ [시간 차이] {time_diff:.1f}분 (현재: {now_str}, 이벤트: {event_datetime_str})")
                                # 10~40분 범위 체크 (30분 전 알림, 놓쳐도 10분 전까지는 발송)
                                if 10 <= time_diff <= 40:
                                    # ★ 이미 알림 발송된 일정은 캐시에 저장하지 않음 (중복 방지)
                                    if is_notified or event_data.get("travel_notified"):
                                        logger.info(f"   ⏭️ [캐싱 스킵] 이미 발송됨: {task_name}")
                                        continue
                                    # 캐시에 저장 (문서 참조와 인덱스도 저장)
                                    schedule_cache[user_id][event_datetime_str] = {
                                        "data": event_data,
                                        "doc_ref": doc_snapshot.reference,  # 컬렉션 그룹 쿼리에서 reference 사용
                                        "doc_date": date_str,
                                        "event_idx": idx
                                    }
                                    total_events += 1
                                    user_events_count += 1
                                    logger.info(f"   📅 [일정 캐싱] {task_name}")
                                else:
                                    logger.debug(f"   ⏭️ [범위 외] time_diff={time_diff:.1f}분")
                            except ValueError as ve:
                                logger.warning(f"   ⚠️ 잘못된 datetime 형식: {event_datetime_str}, 에러: {ve}")
                                continue

                        if user_events_count > 0:
                            logger.info(f"👤 [사용자 요약] user={user_id[:20]}..., ±10분 내 이벤트: {user_events_count}개")

                cache_last_updated = now
                logger.info(f"")
                logger.info(f"{'='*60}")
                logger.info(f"✅ [일정 캐시 갱신 완료]")
                logger.info(f"   📅 총 캐싱된 일정: {total_events}개")
                logger.info(f"{'='*60}")
                logger.info(f"")

            # [알림 발송] - 캐시에서 현재 시간과 일치하는 항목 확인
            sent_count = 0
            pending_count = 0

            # ★ 발송할 항목을 먼저 수집 (순회 중 삭제 방지)
            items_to_notify = []

            for user_id, events_dict in schedule_cache.items():
                for event_time_str, cache_item in events_dict.items():
                    if not cache_item["data"].get("is_notified"):
                        # ★ 이미 발송된 알림인지 메모리에서 체크 (가장 확실한 중복 방지)
                        notification_key = f"{user_id}_{event_time_str}"
                        if notification_key not in sent_notifications:
                            items_to_notify.append((user_id, event_time_str, cache_item))
                            pending_count += 1

            logger.info(f"📬 [일정 발송 체크] 현재 시간={now_str}, 발송 대기 중: {pending_count}개")

            # ★ 수집된 항목만 처리 (딕셔너리 순회 문제 해결)
            for user_id, event_time_str, cache_item in items_to_notify:
                event_data = cache_item["data"]

                # ★ 발송 키 생성 (중복 방지의 핵심)
                notification_key = f"{user_id}_{event_time_str}"

                # ★ 이미 발송된 알림인지 다시 한번 체크 (레이스 컨디션 방지)
                if notification_key in sent_notifications:
                    logger.debug(f"   ⏭️ [스킵] 이미 발송됨 (sent_notifications): {notification_key}")
                    continue

                if event_data.get("is_notified") or event_data.get("travel_notified"):
                    logger.debug(f"   ⏭️ [스킵] 이미 발송됨: user={user_id}")
                    continue

                # 사용자 현재 위치 가져오기 (이동 시간 계산용)
                user_doc = memory_mgr.db.collection("users").document(user_id).get()
                user_data = user_doc.to_dict() if user_doc.exists else {}
                current_lat = user_data.get("currentLat")
                current_lng = user_data.get("currentLng")

                # 시간 차이 계산
                try:
                    event_time = datetime.datetime.strptime(event_time_str, "%Y-%m-%d %H:%M").replace(tzinfo=KST)
                    time_diff = (event_time - now).total_seconds() / 60
                except:
                    continue

                task_name = event_data.get("summary") or "예정된 일정"
                location = event_data.get("location", "")
                partner = event_data.get("partner", "")
                remaining_min = int(time_diff)

                # ============================================
                # [알림 발송 조건 판단]
                # 1. 이동 시간 기반 알림 (위치+장소 정보 있을 때) - 우선
                # 2. 고정 시간 알림 (15~35분 전) - 이동 알림 없을 때만
                # ※ 둘 중 하나만 발송 (중복 방지)
                # ============================================
                should_notify = False
                notification_title = ""
                notification_body = ""
                notification_type = "schedule"
                notification_speech = ""

                # [1] 이동 시간 기반 알림 체크 (우선)
                if current_lat and current_lng and location:
                    # 목적지 좌표 확인
                    dest_lat = event_data.get("dest_lat")
                    dest_lng = event_data.get("dest_lng")

                    # 좌표 없으면 검색 (★ 사용자 위치 기반 주변 검색!)
                    if not dest_lat or not dest_lng:
                        coords = routing_mgr.get_coordinates(location, user_lat=current_lat, user_lng=current_lng)
                        if coords:
                            dest_lat, dest_lng = coords
                            event_data["dest_lat"] = dest_lat
                            event_data["dest_lng"] = dest_lng

                    # 이동 시간 계산
                    if dest_lat and dest_lng and 0 < time_diff <= 120:
                        travel_min = routing_mgr.get_walking_time(current_lat, current_lng, dest_lat, dest_lng)

                        if travel_min is not None:  # 0분도 유효한 값
                            buffer_min = 30  # 준비 시간
                            time_to_leave = travel_min + buffer_min

                            # 출발해야 할 시점이면 알림
                            if time_diff <= time_to_leave:
                                should_notify = True
                                notification_title = "🚶 지금 출발하셔야 해요!"
                                notification_body = f"어르신, '{task_name}'까지 걸어서 {travel_min}분 걸려요. 천천히 준비해서 나가세요."
                                notification_type = "travel_reminder"
                                notification_speech = f"어르신, {task_name} 가실 시간이에요. 걸어서 {travel_min}분 걸립니다. 지금 출발하세요."
                                # 이동 알림 + 일반 알림 모두 발송 완료 표시 (중복 방지)
                                event_data["travel_notified"] = True
                                event_data["is_notified"] = True
                                logger.info(f"")
                                logger.info(f"{'='*60}")
                                logger.info(f"🚶 [이동 알림 발송! - 도보 {travel_min}분]")
                                logger.info(f"   👤 사용자: {user_id}")
                                logger.info(f"   📝 제목: {task_name}")
                                logger.info(f"   ⏰ 예정 시간: {event_time_str}")
                                logger.info(f"   📍 장소: {location}")
                                logger.info(f"   🕐 남은 시간: {remaining_min}분, 필요 시간: {time_to_leave}분")
                                logger.info(f"{'='*60}")

                # [2] 고정 시간 알림 (15~35분 전, 이동 알림이 아닐 때)
                if not should_notify and 15 <= time_diff <= 35:
                    should_notify = True
                    notification_title = "📅 일정 알림"
                    notification_body = f"어르신, {remaining_min}분 후에 {task_name} 있어요~"
                    if location:
                        notification_body += f" (장소: {location})"
                    notification_type = "schedule"
                    notification_speech = f"어르신, {remaining_min}분 후에 {task_name} 있어요."
                    if location:
                        notification_speech += f" 장소는 {location}입니다."
                    logger.info(f"")
                    logger.info(f"{'='*60}")
                    logger.info(f"📅 [일정 알림 발송! - {remaining_min}분 전]")
                    logger.info(f"   👤 사용자: {user_id}")
                    logger.info(f"   📝 제목: {task_name}")
                    logger.info(f"   ⏰ 예정 시간: {event_time_str}")
                    logger.info(f"   📍 장소: {location or '미지정'}")
                    logger.info(f"   👥 상대방: {partner or '미지정'}")
                    logger.info(f"{'='*60}")

                # [알림 발송]
                if should_notify:
                    fcm_token = memory_mgr.get_user_fcm_token(user_id)
                    if fcm_token:
                        if send_fcm_notification(fcm_token, notification_title, notification_body, data={"type": notification_type, "speech": notification_speech}):
                            sent_count += 1
                            pending_count -= 1
                            logger.info(f"[FCM 발송 성공] {notification_type}")
                            logger.info(f"[발송 현황] 발송 완료: {sent_count}개, 남은 예정: {pending_count}개")

                            # ★★★ 발송 완료 즉시 sent_notifications에 추가 (가장 중요!) ★★★
                            sent_notifications.add(notification_key)
                            logger.info(f"🔒 [중복 방지] {notification_key} 등록됨")

                            # [업데이트] is_notified를 True로 변경
                            event_data["is_notified"] = True

                            # Firestore 업데이트 (해당 날짜 문서의 events 배열 재로드 후 수정)
                            doc_ref = cache_item["doc_ref"]
                            doc_date = cache_item["doc_date"]
                            event_idx = cache_item["event_idx"]

                            # 최신 문서 다시 가져오기
                            fresh_doc = doc_ref.get()
                            if fresh_doc.exists:
                                fresh_events = fresh_doc.to_dict().get("events", [])
                                if event_idx < len(fresh_events):
                                    # 암호화하여 저장
                                    if cipher:
                                        fresh_events[event_idx] = CryptoManager.encrypt(json.dumps(event_data, ensure_ascii=False))
                                    else:
                                        fresh_events[event_idx] = event_data
                                    doc_ref.update({"events": fresh_events})
                                    logger.info(f"📝 [Firestore 업데이트] is_notified=True 저장 완료")
                        else:
                            logger.error(f"❌ [FCM 발송 실패] user={user_id}")
                    else:
                        logger.warning(f"❌ [FCM 토큰 없음] user={user_id} - 알림 전송 불가")

            if sent_count > 0:
                logger.info(f"")
                logger.info(f"{'='*60}")
                logger.info(f"📤 [발송 완료 요약]")
                logger.info(f"   ✅ 이번 사이클 발송: {sent_count}개")
                logger.info(f"   ⏳ 남은 발송 예정: {pending_count}개")
                logger.info(f"{'='*60}")

    except Exception as e:
        logger.error(f"⚠️ 스케줄러 에러: {e}", exc_info=True)
    finally:
        schedule_lock.release()

# 약 복용 스케줄러 전용 락 (일정 스케줄러와 충돌 방지)
medication_lock = threading.Lock()
# 중복 발송 방지: {"user_id:alarm_id:HH:MM"} 형태로 이미 보낸 알림 기록
sent_medication_alerts: set = set()
sent_medication_alerts_date: str = ""  # 날짜 변경 시 초기화용

def check_medication_reminders():
    """약 복용 알림 체크 (medicine_event 컬렉션 기반)"""
    if not medication_lock.acquire(blocking=False):
        logger.debug("🔒 [약 스케줄러] 이미 실행 중 - 스킵")
        return
    try:
        if not memory_mgr.db: return
        try:
            global sent_medication_alerts, sent_medication_alerts_date
            now = datetime.datetime.now(KST)
            current_time_str = now.strftime("%H:%M")
            current_date_str = now.strftime("%Y-%m-%d")
            current_weekday = now.weekday() + 1  # 0=월요일, 6=일요일 (Firestore와 동일)

            # 날짜가 바뀌면 중복 방지 세트 초기화
            if sent_medication_alerts_date != current_date_str:
                sent_medication_alerts = set()
                sent_medication_alerts_date = current_date_str
                logger.info(f"🗓️ [약 스케줄러] 날짜 변경 감지 -> 중복방지 초기화")

            logger.info(f"")
            logger.info(f"{'='*60}")
            logger.info(f"💊 [약 복용 스케줄러 실행]")
            logger.info(f"   ⏰ 현재 시간: {current_time_str}")
            logger.info(f"   📅 현재 요일: {current_weekday} (1=월~7=일)")
            logger.info(f"{'='*60}")

            # 모든 사용자의 medicine_event 조회
            users = memory_mgr.db.collection("users").stream()
            total_alarms_checked = 0
            total_alarms_sent = 0
            total_users = 0

            for user_doc in users:
                user_id = user_doc.id
                total_users += 1

                # medicine_event 컬렉션에서 활성화된 알림만 먼저 조회 (시간 필터 제거 - 수동 비교)
                alarms = memory_mgr.db.collection("users").document(user_id)\
                            .collection("medicine_event")\
                            .where(filter=firestore.FieldFilter("is_active", "==", True))\
                            .stream()

                for alarm in alarms:
                    data = alarm.to_dict()
                    alarm_time = data.get("alarm_time", "")
                    repeat_days = data.get("repeat_days", [])  # 예: [1, 3, 5] = 월, 수, 금
                    med_name = data.get("medication_name", "약")
                    alarm_id = alarm.id

                    # 시간 비교 (다양한 형식 지원)
                    # alarm_time이 "9:00" 또는 "09:00" 형식일 수 있음
                    alarm_time_normalized = alarm_time
                    if ':' in alarm_time and len(alarm_time.split(':')[0]) == 1:
                        alarm_time_normalized = alarm_time.zfill(5)  # "9:00" -> "09:00"

                    time_match = (current_time_str == alarm_time or current_time_str == alarm_time_normalized)

                    if time_match:
                        total_alarms_checked += 1
                        logger.info(f" 📋 [알림 확인] user={user_id[:20]}..., 약={med_name}, alarm_time={alarm_time}, repeat_days={repeat_days}")

                        # 오늘 요일이 반복 요일에 포함되는지 확인
                        if current_weekday in repeat_days:
                            # ★ 중복 발송 방지: 이미 이 시간에 보냈으면 스킩
                            alert_key = f"{user_id}:{alarm_id}:{current_time_str}"
                            if alert_key in sent_medication_alerts:
                                logger.debug(f"   ⏭️ [이미 발송됨] {med_name} @ {current_time_str}")
                                continue

                            fcm_token = memory_mgr.get_user_fcm_token(user_id)

                            if fcm_token:
                                logger.info(f"")
                                logger.info(f"{'='*60}")
                                logger.info(f"💊 [약 복용 알림 발송!]")
                                logger.info(f"   👤 사용자: {user_id}")
                                logger.info(f"   💊 약 이름: {med_name}")
                                logger.info(f"   ⏰ 알림 시간: {current_time_str}")
                                logger.info(f"   📅 반복 요일: {repeat_days}")
                                logger.info(f"{'='*60}")

                                success = send_fcm_notification(
                                    fcm_token,
                                    "💊 약 드실 시간이에요",
                                    f"어르신, {med_name} 드셔야 할 시간입니다.",
                                    data={
                                        "type": "medication_alarm",
                                        "medicine_id": alarm_id,
                                        "medication_name": med_name,
                                        "retry_count": "0"
                                    },
                                    priority="high"
                                )
                                if success:
                                    total_alarms_sent += 1
                                    sent_medication_alerts.add(alert_key)
                                    logger.info(f"   ✅ [알림 발송 성공] (중복방지 등록: {alert_key})")
                            else:
                                logger.warning(f"   ❌ [FCM 토큰 없음] user={user_id}")
                        else:
                            logger.info(f"   ⏭️ [요일 불일치] 오늘={current_weekday}, 설정={repeat_days}, 약={med_name}")

            logger.info(f"")
            logger.info(f"💊 [약 복용 스케줄러 완료] 사용자: {total_users}명, 시간 일치: {total_alarms_checked}개, 발송: {total_alarms_sent}개")

        except Exception as e:
            logger.error(f"❌ 약 알림 스케줄러 에러: {e}", exc_info=True)
    finally:
        medication_lock.release()

def daily_health_check():
    """매일 아침 안부 인사"""
    if datetime.datetime.now(KST).hour != 9: return
    with scheduler_lock() as acquired:
        if not acquired or not memory_mgr.db: return
        try:
            users = memory_mgr.db.collection("users").where(field_path="healthCheckEnabled", op_string="==", value=True).stream()
            for user in users:
                token = user.to_dict().get("fcmToken")
                if token:
                    send_fcm_notification(token, "🌅 좋은 아침이에요!", "어르신, 오늘 기분은 어떠세요?", data={"type": "health_check"})
        except Exception as e:
            logger.error(f"건강 체크 에러: {e}")

scheduler = BackgroundScheduler()
# ★ max_instances=1: 이전 job이 실행 중이면 새 job 시작 안 함 (중복 실행 방지)
scheduler.add_job(check_schedules, 'interval', minutes=0.2, id='schedule_check', max_instances=1, coalesce=True)
scheduler.add_job(check_medication_reminders, 'interval', minutes=0.2, id='medication_check', max_instances=1, coalesce=True)
scheduler.add_job(daily_health_check, 'cron', hour=9, minute=0, id='health_check', max_instances=1)

# 스케줄러 시작 전 상태 체크
logger.info("="*60)
logger.info("🚀 [스케줄러 초기화]")
logger.info(f"   📦 Firebase DB 상태: {'✅ 연결됨' if memory_mgr.db else '❌ 미연결'}")
logger.info(f"   👤 MemoryManager 상태: {'✅ 초기화됨' if memory_mgr else '❌ 미초기화'}")
if not memory_mgr.db:
    logger.warning("   ⚠️ DB 미연결 - 스케줄러 첫 실행 시 재연결 시도 예정")
logger.info("="*60)
scheduler.start()

# ===========================================================
# [7] API 엔드포인트
# ===========================================================
class TokenRequest(BaseModel):
    token: str
    guardian_token: Optional[str] = None
class HealthStatusRequest(BaseModel):
    mood: str
    pain_level: int
    sleep_quality: str
    notes: Optional[str] = None
class MedicationConfirmRequest(BaseModel):
    medicine_id: str       # Firestore 문서 ID
    medication_name: str   # 약 이름
    status: str            # "taken" (복용) 또는 "missed" (미복용)
    retry_count: int = 0   # 0: 첫 응답, 1: 재알림 후 응답

@app.get("/")
async def root():
    return {"status": "running", "service": "치매 어르신 기억 회상 AI 비서 V2.1", "timestamp": datetime.datetime.now(KST).isoformat()}

@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "firebase": "connected" if memory_mgr.db else "disconnected",
        "active_connections": len(memory_mgr.active_connections)
    }

@app.post("/update-token")
async def update_fcm_token(req: TokenRequest, user_id: str = Depends(get_current_user)):
    if memory_mgr.db:
        update_data = {"fcmToken": req.token}
        if req.guardian_token: update_data["guardianFcmToken"] = req.guardian_token
        memory_mgr.db.collection("users").document(user_id).set(update_data, merge=True)
        return {"status": "success"}
    return {"status": "error"}

@app.post("/health-status")
async def update_health_status(req: HealthStatusRequest, user_id: str = Depends(get_current_user)):
    memory_mgr.save_health_status(user_id, req.dict())
    if req.mood == "bad" or req.pain_level >= 7:
        send_emergency_alert(user_id, f"기분: {req.mood}, 통증: {req.pain_level}/10")
    return {"status": "recorded"}

@app.post("/medication-confirm")
async def confirm_medication(req: MedicationConfirmRequest, user_id: str = Depends(get_current_user)):
    """
    앱에서 약 복용/미복용 버튼을 눌렀을 때 호출
    """
    if not memory_mgr.db:
        return {"status": "error", "message": "DB disconnected"}

    try:
        current_time = datetime.datetime.now(KST)
        date_str = current_time.strftime("%Y-%m-%d")
        timestamp_str = current_time.strftime("%H:%M:%S")

        # 로그 데이터 구성
        log_data = {
            "medicine_id": req.medicine_id,
            "medication_name": req.medication_name,
            "status": req.status,          # taken / missed
            "timestamp": timestamp_str,
            "retry_count": req.retry_count,
            "recorded_at": current_time
        }

        # 보호자 토큰 조회
        guardian_token = memory_mgr.get_guardian_token(user_id)
        user_name = memory_mgr.get_user_name(user_id)

        # ==========================================
        # [Case 1] 복용 완료 (Taken)
        # ==========================================
        if req.status == "taken":
            # 1. 결과 저장 (Stacking)
            result_ref = memory_mgr.db.collection("users").document(user_id).collection("medicine_result").document(date_str)

            result_ref.set({
                "logs": firestore.ArrayUnion([log_data]),
                "last_updated": current_time
            }, merge=True)

            logger.info(f"✅ [약 복용 완료] {user_id} - {req.medication_name}")

            # 2. 보호자 알림
            if guardian_token:
                send_fcm_notification(
                    guardian_token,
                    "✅ 약 복용 완료",
                    f"{user_name} 어르신이 '{req.medication_name}' 복용을 완료하셨습니다.",
                    data={"type": "medication_result", "status": "taken"}
                )

        # ==========================================
        # [Case 2] 미복용 (Missed)
        # ==========================================
        elif req.status == "missed":

            # A. 첫 번째 미복용 -> 5분 뒤 재알림 예약
            if req.retry_count == 0:
                logger.info(f"⏳ [미복용 1차] 5분 뒤 재알림 예약: {user_id}")

                # 스케줄러에 1회성 작업 등록
                run_date = datetime.datetime.now(KST) + datetime.timedelta(minutes=5)
                scheduler.add_job(
                    send_medication_retry,
                    'date',
                    run_date=run_date,
                    args=[user_id, req.medicine_id, req.medication_name]
                )
                return {"status": "retry_scheduled", "message": "5분 뒤 재알림 예정"}

            # B. 재알림 후에도 미복용 -> 결과 저장 및 보호자 알림
            else:
                logger.warning(f"❌ [미복용 확정] {user_id} - {req.medication_name}")

                # 1. 결과 저장 (Stacking)
                result_ref = memory_mgr.db.collection("users").document(user_id).collection("medicine_result").document(date_str)

                result_ref.set({
                    "logs": firestore.ArrayUnion([log_data]),
                    "last_updated": current_time
                }, merge=True)

                # 2. 보호자에게 경고 알림
                if guardian_token:
                    send_fcm_notification(
                        guardian_token,
                        "⚠️ 약 미복용 알림",
                        f"{user_name} 어르신이 재알림 후에도 '{req.medication_name}'을 드시지 않았습니다!!.",
                        data={"type": "medication_result", "status": "missed_final"},
                        priority="high"
                    )

        return {"status": "success"}

    except Exception as e:
        logger.error(f"약 복용 확인 처리 중 오류: {e}")
        return {"status": "error", "message": str(e)}

@app.get("/conversations")
async def get_conversations(date: Optional[str] = None, user_id: str = Depends(get_current_user)):
    target_date = date or datetime.datetime.now(KST).strftime("%Y-%m-%d")
    if not memory_mgr.db: return {"messages": []}
    doc = memory_mgr.db.collection("users").document(user_id).collection("conversations").document(target_date).get()
    return doc.to_dict() if doc.exists else {"messages": [], "date": target_date}

# ===========================================================
# [8] WebSocket 채팅 엔드포인트 (★ 최적화 적용 ★)
# ===========================================================
@app.websocket("/ws/chat")
async def websocket_endpoint(
    websocket: WebSocket,
    token: str = Query(..., description="Firebase ID Token")
):
    user_id = None  # finally에서 사용하기 위해 미리 선언

    # 1. 인증 및 연결 수락
    try:
        user_id = verify_firebase_token(token)
    except Exception as auth_error:
        logger.error(f"❌ 인증 실패: {auth_error}")
        try:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        except:
            pass
        return

    try:
        await websocket.accept()
        logger.info(f"WebSocket 연결됨: {user_id}")
    except Exception as accept_error:
        logger.error(f"❌ WebSocket accept 실패: {accept_error}")
        return

    # [★ 핵심 추가: 세션 시작 시 기억 로드]
    try:
        memory_count = await memory_mgr.load_memories_for_user(user_id)
        logger.info(f"📥 [{user_id}] 기억 {memory_count}개 로드 완료")
    except Exception as e:
        logger.error(f"❌ 기억 로드 실패: {e}")

    # 사용자 이름 가져오기
    try:
        user_name = await asyncio.to_thread(memory_mgr.get_user_name, user_id)
        logger.info(f"👤 사용자 이름 로드: {user_name}")
        chat_history = await asyncio.to_thread(memory_mgr.get_recent_chat_history, user_id)
    except Exception as e:
        logger.error(f"❌ 사용자 정보 로드 실패: {e}")
        user_name = "어르신"
        chat_history = ""

    # 활성 연결에 등록
    memory_mgr.active_connections[user_id] = websocket
    # Gemini 클라이언트
    client = genai.Client(api_key=MY_API_KEY, http_options={"api_version": "v1alpha"})
    # [중요] 텍스트 채팅에서는 도구(Tool)를 AI가 호출하게 기다리지 않고,
    # 서버가 먼저 검색해서 주입하므로 tools 설정을 최소화하거나 유지하되 의존도를 낮춥니다.
    search_tool = types.Tool(function_declarations=[
        types.FunctionDeclaration(
            name="search_memory",
            description="Queries past memories.",
            parameters=types.Schema(
                type=types.Type.OBJECT,
                properties={"query": types.Schema(type=types.Type.STRING)},
                required=["query"]
            )
        )
    ])

    # 시스템 프롬프트 로드
    sys_prompt = memory_mgr.construct_system_prompt(user_name=user_name, chat_history=chat_history)

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=sys_prompt)]),
        tools=[search_tool], # 오디오 입력을 위해 도구 유지는 하되, 텍스트 입력엔 안 씀
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Puck"))
        ),
        input_audio_transcription=types.AudioTranscriptionConfig()  # 사용자 음성 transcript 활성화
    )

    try:
        max_reconnect_attempts = 5
        reconnect_count = 0
        while reconnect_count < max_reconnect_attempts:
            try:
                async with client.aio.live.connect(model=MODEL_ID, config=config) as session:
                    logger.info(f"🤖 Gemini 연결됨: {user_id}")
                    reconnect_count = 0
                    session_active = True

                    async def receive_from_client():
                        nonlocal session_active
                        while session_active:
                            try:
                                message = await websocket.receive()
                                if message.get("type") == "websocket.disconnect":
                                    session_active = False
                                    break
                                if "text" in message and message["text"]:
                                    data = json.loads(message["text"])
                                    msg_type = data.get("type")
                                    if msg_type == "text_input":
                                        text = data.get("content", "")
                                        if text:
                                            # 1. 대화 로그 저장
                                            if memory_mgr.conversation_logger:
                                                memory_mgr.conversation_logger.add_message(user_id, "user", text)
                                                preview = text[:30] if len(text) > 30 else text
                                                logger.info(f"📝 [대화 로그 저장] user={user_id}, text={preview}...")

                                            # [★ 핵심 수정: 선제적 기억 검색 (Pre-fetching)]
                                            memory_context = ""
                                            try:
                                                # 검색은 빠르게 (타임아웃 2초)
                                                memory_result = await asyncio.wait_for(
                                                    asyncio.to_thread(memory_mgr.search_memory, user_id, text, client),
                                                    timeout=2.0
                                                )
                                                if "관련 기억" in memory_result or "최근 기록" in memory_result:
                                                    memory_context = f"\n[시스템 참고 정보: {memory_result}]"
                                                    logger.info(f"⚡ [선제적 검색 성공] {memory_result[:30]}...")
                                            except Exception:
                                                pass # 검색 실패해도 대화는 계속

                                            # 3. AI에게 전송 (기억 정보를 몰래 붙여서 보냄)
                                            final_input = text + memory_context
                                            await session.send(input=final_input, end_of_turn=True)

                                    elif msg_type == "commit":
                                        # 오디오 커밋 시에는 어쩔 수 없이 도구 호출에 의존 (텍스트가 없으므로)
                                        await session.send(input={"data": b'', "mime_type": "audio/pcm"}, end_of_turn=True)

                                elif "bytes" in message and message["bytes"]:
                                    await session.send(input={"data": message["bytes"], "mime_type": "audio/pcm"}, end_of_turn=False)


                            except WebSocketDisconnect:
                                session_active = False
                                break
                            except Exception:
                                session_active = False
                                break

                    async def send_to_client():
                        nonlocal session_active
                        accumulated_text = ""
                        user_transcript = ""  # 사용자 음성 transcript 누적
                        is_responding = False

                        while session_active:
                            try:
                                async for response in session.receive():
                                    if not session_active: break

                                    # [★ 사용자 음성 transcript 수신]
                                    if response.server_content and response.server_content.input_transcription:
                                        transcript_text = response.server_content.input_transcription.text
                                        if transcript_text:
                                            user_transcript += transcript_text

                                            # 긴급 상황 체크 (사용자 발화 기반)
                                            is_emergency, reason = EmergencyDetector.check_emergency(transcript_text)
                                            if is_emergency:
                                                logger.warning(f"🚨 [오디오 긴급 감지] user={user_id}, transcript={transcript_text[:30]}, reason={reason}")
                                                await asyncio.to_thread(send_emergency_alert, user_id, reason)

                                            # 대화 로그에 사용자 발화 저장
                                            if memory_mgr.conversation_logger:
                                                memory_mgr.conversation_logger.add_message(user_id, "user", transcript_text)

                                    # [Case A] 도구 호출 (오디오 입력일 경우 발생)
                                    if response.tool_call:
                                        for call in response.tool_call.function_calls:
                                            logger.info(f"🔧 Tool 호출: {call.name}")
                                            result = await asyncio.to_thread(
                                                memory_mgr.search_memory, user_id, call.args.get("query", ""), client
                                            )
                                            await session.send_tool_response(
                                                function_responses=[
                                                    types.FunctionResponse(name=call.name, id=call.id, response={"result": result})
                                                ]
                                            )

                                    if response.server_content and response.server_content.model_turn:
                                        for part in response.server_content.model_turn.parts:
                                            if part.text:
                                                raw = part.text
                                                # [★ 핵심 수정] AI 생각(Thought) 필터링
                                                # Gemini가 생각하는 과정(**...**)을 출력하면 건너뜀
                                                if raw.strip().startswith("**") or "Thinking" in raw or "Clarifying" in raw:
                                                    continue

                                                chunk = raw
                                                if len(chunk.strip()) > 0:
                                                    if not is_responding: is_responding = True
                                                    await websocket.send_json({"type": "text_chunk", "content": chunk})
                                                    # 필터링된 '진짜 답변'만 누적
                                                    accumulated_text += chunk

                                            # 오디오 데이터 전송
                                            if part.inline_data and part.inline_data.data:
                                                await websocket.send_bytes(part.inline_data.data)

                                        # 턴 종료 처리
                                        if response.server_content.turn_complete:
                                            if is_responding:
                                                await websocket.send_json({"type": "text_end"})

                                            if accumulated_text and memory_mgr.conversation_logger:
                                                memory_mgr.conversation_logger.add_message(user_id, "ai", accumulated_text)
                                            accumulated_text = ""
                                            user_transcript = ""  # 턴 종료 시 초기화
                                            is_responding = False

                            except Exception as e:
                                logger.warning(f"⚠️ Gemini 스트림 재대기: {e}")
                                if "Session closed" in str(e): break
                                await asyncio.sleep(0.1)

                    # 태스크 실행
                    t_client = asyncio.create_task(receive_from_client())
                    t_gemini = asyncio.create_task(send_to_client())

                    done, pending = await asyncio.wait([t_client, t_gemini], return_when=asyncio.FIRST_COMPLETED)
                    for t in pending: t.cancel()
                    session_active = False

                    # 정상 종료 시 재연결 루프 탈출
                    if not websocket.client_state.name == "CONNECTED":
                        break
                    # 연결은 살아있는데 세션만 죽은 경우 재연결 시도
                    await asyncio.sleep(0.5)

            except Exception as e:
                logger.error(f"❌ Gemini 연결 오류: {e}")
                reconnect_count += 1
                await asyncio.sleep(2)

    except Exception as e:
        logger.error(f"❌ WebSocket 핸들러 오류: {e}")
    finally:
        # user_id가 None이면 처리 불필요
        if user_id is None:
            logger.info("🔌 [연결 종료] 인증 실패로 user_id 없음")
            return

        # 연결 종료 처리
        logger.info(f"🔌 [연결 종료] user={user_id}")

        # 활성 연결에서 제거
        if user_id in memory_mgr.active_connections:
            del memory_mgr.active_connections[user_id]
            logger.info(f"🗑️ [연결 제거] user={user_id} - 활성 연결에서 제거됨")

        try:
            await websocket.close()
        except:
            pass
        logger.info(f"👋 [세션 종료] user={user_id} - WebSocket 연결 종료 완료")

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    scheduler.shutdown(wait=False)
    memory_mgr.memory_cache.clear()
    logger.info("👋 서버가 안전하게 종료되었습니다.")

app.router.lifespan_context = lifespan

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        reload=False,
        log_level="info",
        access_log=False
    )
