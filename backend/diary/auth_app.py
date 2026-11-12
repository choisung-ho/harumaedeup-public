import firebase_admin
from firebase_admin import credentials, firestore, auth, storage
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, EmailStr, field_validator
from typing import Optional
from datetime import datetime
import os
import random  # ✅ 난수 생성을 위해 추가
import string  # ✅ 난수 생성을 위해 추가

# ==========================================
# [설정] Firebase 초기화
# ==========================================
STORAGE_BUCKET_NAME = os.getenv("STORAGE_BUCKET_NAME")
PROJECT_ID = os.environ.get("GCLOUD_PROJECT")

# ✅ Firebase 초기화 (Cloud Functions 환경에서는 credentials 없이 가능)
if not firebase_admin._apps:
    firebase_admin.initialize_app(options={
        'projectId': os.getenv("GCLOUD_PROJECT"),
        'storageBucket': os.getenv("STORAGE_BUCKET_NAME")
    })

app = FastAPI(title="DailyEnd Auth Server")

def get_db():
    return firestore.client()

# ✅ 6자리 난수 생성 함수 추가
def generate_connect_code():
    return ''.join(random.choices(string.digits, k=6))

# ==========================================
# [Models] 데이터 구조
# ==========================================
class UserSignup(BaseModel):
    userId: EmailStr
    password: str
    name: str
    gender: str
    birth: str
    phone: str
    homeLat: float
    homeLng: float
    fcmToken: Optional[str] = None
    guardianId: Optional[str] = None
    guardianFcmToken: Optional[str] = None
    role: int

    @field_validator('password')
    def validate_password(cls, v):
        if len(v) < 6:
            raise ValueError('비밀번호는 6자 이상이어야 합니다.')
        return v

    @field_validator('role')
    def validate_role(cls, v):
        if v not in [1, 2]:
            raise ValueError('Role은 1 또는 2여야 합니다.')
        return v

class GoogleSignup(BaseModel):
    uid: str
    userId: EmailStr
    name: str
    gender: str
    birth: str
    phone: str
    homeLat: float
    homeLng: float
    fcmToken: Optional[str] = None
    guardianId: Optional[str] = None
    guardianFcmToken: Optional[str] = None
    role: int

    @field_validator('role')
    def validate_role(cls, v):
        if v not in [1, 2]:
            raise ValueError('Role Error')
        return v

class FCMTokenRequest(BaseModel):
    token: str

# ==========================================
# [API] Endpoints
# ==========================================
@app.get("/")
def read_root():
    return {"status": "ok", "service": "Auth Server is Running (Sync Mode)"}

@app.post("/signup", status_code=201)
def signup(user: UserSignup):
    """일반 이메일 회원가입"""
    print(f"👉 [1] 회원가입 시작: {user.userId}")

    created_uid = None  # ✅ 롤백용 변수 선언

    try:
        # 1단계: Firebase Auth 사용자 생성
        print("👉 [2] Firebase Auth 생성 시도...")
        user_record = auth.create_user(
            email=user.userId,
            password=user.password,
            display_name=user.name
        )
        created_uid = user_record.uid  # ✅ 롤백용 저장
        print(f"👉 [3] Auth 생성 완료: {user_record.uid}")

        # 2단계: Firestore에 사용자 정보 저장
        print("👉 [4] Firestore 저장 시도...")
        _save_user_to_firestore(user_record.uid, user)
        print("👉 [5] Firestore 저장 완료!")

        return {"message": "회원가입 성공", "uid": user_record.uid}

    except auth.EmailAlreadyExistsError:
        print(f"❌ [Error] 이미 존재하는 이메일: {user.userId}")
        raise HTTPException(status_code=409, detail="이미 가입된 이메일입니다.")

    except Exception as e:
        # ✅ DB 저장 실패 시 Auth 계정 롤백
        if created_uid:
            try:
                auth.delete_user(created_uid)
                print(f"⚠️ [Rollback] DB 저장 실패로 Auth 계정 삭제함: {created_uid}")
            except Exception as rollback_error:
                print(f"⚠️ [Rollback 실패] {rollback_error}")

        print(f"❌ [Error] 회원가입 중 오류: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/google_signup", status_code=201)
def google_signup(user: GoogleSignup):
    """구글 회원가입 (추가 정보 저장)"""
    print(f"👉 [1] 구글 회원가입 시작: {user.userId}, UID: {user.uid}")

    try:
        # Firestore에 사용자 정보 저장
        print("👉 [2] Firestore 저장 시도...")
        _save_user_to_firestore(user.uid, user)
        print("👉 [3] Firestore 저장 완료!")

        return {"message": "구글 회원가입 성공", "uid": user.uid}

    except Exception as e:
        print(f"❌ [Error] 구글 회원가입 중 오류: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/update-token")
def update_token(request: Request, item: FCMTokenRequest):
    """FCM 토큰 업데이트"""
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid Authorization header")

    id_token = auth_header.split(" ")[1]
    try:
        decoded_token = auth.verify_id_token(id_token)
        uid = decoded_token['uid']
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid ID Token")

    try:
        db = get_db()
        user_ref = db.collection("users").document(uid)
        user_doc = user_ref.get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="User not found")

        user_ref.update({"fcmToken": item.token})

        user_data = user_doc.to_dict()
        role = user_data.get("role")

        # 상대방 토큰 동기화
        target_uid = None
        target_field = ""
        if role == 1:
            target_uid = user_data.get("seniorId")
            target_field = "guardianFcmToken"
        elif role == 2:
            target_uid = user_data.get("guardianId")
            target_field = "seniorFcmToken"

        if target_uid:
            db.collection("users").document(target_uid).update({target_field: item.token})

        return {"message": "Token updated successfully"}
    except Exception as e:
        print(f"❌ [Error] Update Token: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/withdraw/{uid}", status_code=200)
def withdraw_user(uid: str):
    """회원 탈퇴"""
    try:
        db = get_db()
        user_doc_ref = db.collection("users").document(uid)
        user_doc = user_doc_ref.get()

        if user_doc.exists:
            data = user_doc.to_dict()
            role = data.get("role")
            target_uid = None
            update_field = ""

            if role == 1:
                target_uid = data.get("seniorId")
                update_field = "guardianId"
            elif role == 2:
                target_uid = data.get("guardianId")
                update_field = "seniorId"

            if target_uid:
                fcm_field = update_field.replace('Id', 'FcmToken')
                db.collection("users").document(target_uid).update({
                    update_field: None,
                    fcm_field: None
                })

        # 하위 컬렉션 삭제
        sub_collections = ["daily_logs", "diary", "calendar_events", "phishing_logs", "user_face", "unknown_faces"]
        for sub_name in sub_collections:
            delete_collection(user_doc_ref.collection(sub_name), 10)

        user_doc_ref.delete()
        delete_user_storage(uid)

        try:
            auth.delete_user(uid)
        except Exception:
            pass

        return {"message": "회원 탈퇴 완료"}
    except Exception as e:
        print(f"❌ [Error] Withdraw: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# [Helper] 유틸리티 함수
# ==========================================
def _save_user_to_firestore(uid: str, user_data):
    """Firestore에 사용자 정보 저장"""
    # Custom Claims 설정
    auth.set_custom_user_claims(uid, {'role': user_data.role})

    # role에 따른 연결 정보 설정
    final_guardian_id = None
    final_guardian_token = None
    final_senior_id = None
    final_senior_token = None

    # ✅ 추가된 변수 초기화
    connect_code = None
    is_connected = False

    if user_data.role == 1:  # 보호자
        final_senior_id = user_data.guardianId
        final_senior_token = user_data.guardianFcmToken
    elif user_data.role == 2:  # 대상자(케어대상자)
        final_guardian_id = user_data.guardianId
        final_guardian_token = user_data.guardianFcmToken
        # ✅ 케어대상자(role: 2)인 경우에만 6자리 난수 코드 생성
        connect_code = generate_connect_code()

    data_to_save = {
        "uid": uid,
        "email": user_data.userId,
        "name": user_data.name,
        "gender": user_data.gender,
        "birth": user_data.birth,
        "phone": user_data.phone,
        "homeLat": user_data.homeLat,
        "homeLng": user_data.homeLng,
        "fcmToken": user_data.fcmToken,
        "guardianId": final_guardian_id,
        "guardianFcmToken": final_guardian_token,
        "seniorId": final_senior_id,
        "seniorFcmToken": final_senior_token,
        "role": user_data.role,
        "connect_code": connect_code,  # ✅ 추가: 케어대상자만 생성됨 (보호자는 None)
        "is_connected": is_connected,  # ✅ 추가: 기본값 False
        "created_at": firestore.SERVER_TIMESTAMP
    }

    db = get_db()
    db.collection("users").document(uid).set(data_to_save)
    print(f"✅ [Firestore] 사용자 저장 완료: {uid} (Code: {connect_code})")

def delete_collection(coll_ref, batch_size: int):
    """컬렉션 재귀 삭제"""
    docs = coll_ref.limit(batch_size).stream()
    deleted = 0
    for doc in docs:
        for sub_coll in doc.reference.collections():
            delete_collection(sub_coll, batch_size)
        doc.reference.delete()
        deleted += 1
    if deleted >= batch_size:
        return delete_collection(coll_ref, batch_size)

def delete_user_storage(uid: str):
    """Storage 파일 삭제"""
    try:
        bucket = storage.bucket(STORAGE_BUCKET_NAME)
        blobs = bucket.list_blobs(prefix=f"Users/{uid}/")
        for blob in blobs:
            blob.delete()
        print(f"✅ [Storage] 사용자 파일 삭제 완료: {uid}")
    except Exception as e:
        print(f"⚠️ [Storage] 삭제 실패 (무시): {e}")
