#  중복사진 제거 및 얼굴인식, Gemini 분석을 위한 Firebase Cloud Functions
import os
import json
import traceback
from datetime import datetime, timedelta, timezone
import PIL.Image
from PIL import ExifTags
from firebase_functions import https_fn, scheduler_fn, storage_fn, options
from firebase_functions.options import MemoryOption
from firebase_admin import initialize_app, firestore, storage
from cryptography.fernet import Fernet
from google import genai

# 1. 초기화
initialize_app()
options.set_global_options(region=options.SupportedRegion.US_CENTRAL1)

# DB 지연 초기화
_db_client = None
def get_db():
    global _db_client
    if _db_client is None:
        _db_client = firestore.client()
    return _db_client

# 2. 설정
BUCKET_NAME = os.getenv("STORAGE_BUCKET_NAME")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
ENCRYPTION_KEY = os.environ.get("ENCRYPTION_KEY")

if not ENCRYPTION_KEY:
    print("!! Warning: ENCRYPTION_KEY not found. Runtime encryption will fail.")
    cipher_suite = None
else:
    try:
        cipher_suite = Fernet(ENCRYPTION_KEY)
    except Exception as e:
        print(f"!! Error initializing Fernet: {e}")
        cipher_suite = None

if not GEMINI_API_KEY:
    print("!! Warning: GEMINI_API_KEY not found.")

# 암호화 헬퍼
def encrypt_data(data):
    # [중요] 런타임에 키가 없으면 에러 발생 (평문 저장 방지)
    if cipher_suite is None:
        raise ValueError("CRITICAL: ENCRYPTION_KEY missing. Cannot encrypt data.")

    if data is None: return None
    try:
        if not isinstance(data, str):
            data_str = json.dumps(data, ensure_ascii=False)
        else:
            data_str = data
        return cipher_suite.encrypt(data_str.encode()).decode()
    except Exception as e:
        print(f"Encrypt Error: {e}")
        return None

def decrypt_data(encrypted_str):
    if not encrypted_str: return None
    # 키 누락 확인
    if cipher_suite is None:
        print("Decrypt Fail: Encryption key not configured (cipher_suite is None)")
        return None

    try:
        decrypted_bytes = cipher_suite.decrypt(encrypted_str.encode())
        return decrypted_bytes.decode()
    except Exception as e:
        # 구체적인 에러 타입 로깅 (예: InvalidToken 등)
        print(f"Decrypt Error: {e} (Type: {type(e).__name__})")
        return None

def encrypt_vector(vector):
    return encrypt_data(vector)

def decrypt_vector(encrypted_str):
    try:
        if not encrypted_str: return None
        dec_str = decrypt_data(encrypted_str)
        return json.loads(dec_str) if dec_str else None
    except: return None

# Gemini 분석 함수
def analyze_image_with_gemini(image_path, known_names):
    if not GEMINI_API_KEY:
        return {"error": "API Key missing"}

    try:
        client = genai.Client(api_key=GEMINI_API_KEY)
        if not os.path.exists(image_path): return None

        img = PIL.Image.open(image_path)
        names_str = ", ".join(known_names) if known_names else "Unknown people"
        prompt = f"""
        Analyze this image strictly based on the 5W1H (Who, When, Where, What, Why, How) framework.
        Context Info: - Identified People: {names_str}
        Output must be a valid JSON object with keys: who, when, where, what, how, why.
        CRITICAL INSTRUCTION: Analyze deeply and output ALL values in natural, native Korean(한국어).
        Respond ONLY with the JSON.
        """

        try:
            response = client.models.generate_content(model='gemini-2.5-pro', contents=[prompt, img])
        except Exception as e1:
            err_msg_1 = str(e1)
            if "429" in err_msg_1 or "RESOURCE_EXHAUSTED" in err_msg_1 or "503" in err_msg_1 or "UNAVAILABLE" in err_msg_1:
                print(f"Gemini Pro overloaded/error ({err_msg_1}), trying Flash...")
                try:
                    response = client.models.generate_content(model='gemini-2.5-flash', contents=[prompt, img])
                except Exception as e2:
                    err_msg_2 = str(e2)
                    if "429" in err_msg_2 or "503" in err_msg_2 or "UNAVAILABLE" in err_msg_2:
                        print(f"Gemini 2.5 Flash overloaded/error ({err_msg_2}), trying 2.5 Flash-Lite...")
                        response = client.models.generate_content(model='gemini-2.5-flash-lite', contents=[prompt, img])
                    else: raise e2
            else: raise e1

        try:
            if not response.text:
                print(f"Gemini Response Blocked or Empty: {response.candidates[0].finish_reason if response.candidates else 'No candidates'}")
                return {"error": "Gemini response blocked/empty", "details": str(response.candidates)}

            txt = response.text.strip()
            if txt.startswith("```"):
                txt = txt.split("\n", 1)[-1].rsplit("\n", 1)[0]
            return json.loads(txt)
        except Exception as parse_error:
            print(f"Gemini Parse Error: {parse_error}, Raw: {response.text}")
            return {"raw_text": response.text}

    except Exception as e:
        print(f"Gemini Error: {e}")
        return {"error": str(e)}

# 모델 설정
ACTIVE_MODELS = ['ArcFace']
THRESHOLDS = {'ArcFace': 0.40}

# ---------------------------------------------------------
# [Trigger 1] 사진 업로드 감지 (사용자별 DB 구조 적용)
# ---------------------------------------------------------
@storage_fn.on_object_finalized(memory=16384, timeout_sec=540, cpu=4, concurrency=1)
def process_upload(event: storage_fn.CloudEvent[storage_fn.StorageObjectData]):
    file_path = event.data.name
    bucket_name = event.data.bucket

    if file_path.endswith('/') or file_path.endswith('.keep'): return
    if "thumbnails/" in file_path or "unknown_faces/" in file_path or "result/faces/" in file_path: return

    path_parts = file_path.split('/')
    uid = None
    root_folder = "users" # 기본값

    if len(path_parts) >= 2:
        valid_roots = ['users', 'Users', 'uploads']
        if path_parts[0] in valid_roots:
            uid = path_parts[1]
            root_folder = path_parts[0] # 대소문자 유지 (Users vs users)
        else:
            uid = path_parts[0]

    if not uid:
        print(f"⚠️ uid를 경로에서 찾을 수 없습니다: {file_path}")
        return

    print(f"🚀 [New Upload] 사용자({uid}) 분석 시작: {file_path}")
    temp_local_path = f"/tmp/{os.path.basename(file_path)}"

    try:
        os.environ['DEEPFACE_HOME'] = '/tmp'
        os.environ['CUDA_VISIBLE_DEVICES'] = '-1'
        os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'

        import cv2
        import numpy as np
        from deepface import DeepFace

        # [로컬 동기화] 안전장치 추가된 필터링 함수
        def is_blurry(image, threshold=50):
            try:
                gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
                laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
                return laplacian_var < threshold
            except: return True

        def is_side_or_back_face(face_obj):
            try:
                facial_area = face_obj.get('facial_area', {})
                w = facial_area.get('w', 0)
                h = facial_area.get('h', 0)
                if w == 0 or h == 0: return True

                aspect_ratio = w / h
                if aspect_ratio < 0.6 or aspect_ratio > 1.5: return True

                confidence = face_obj.get('confidence', 1.0)
                if confidence < 0.85: return True

                keys = facial_area.keys()
                has_left = 'left_eye' in keys or 'eye_left' in keys
                has_right = 'right_eye' in keys or 'eye_right' in keys
                if not (has_left and has_right): return True

                le = facial_area.get('left_eye') or facial_area.get('eye_left')
                re = facial_area.get('right_eye') or facial_area.get('eye_right')
                no = facial_area.get('nose')
                face_x = facial_area.get('x', 0)

                if le and re and no:
                    d_left = ((le[0] - no[0])**2 + (le[1] - no[1])**2)**0.5
                    d_right = ((re[0] - no[0])**2 + (re[1] - no[1])**2)**0.5
                    if d_left == 0 or d_right == 0: return True

                    ratio = min(d_left, d_right) / max(d_left, d_right)
                    if ratio < 0.55: return True

                    if face_x > 0:
                        face_center_x = face_x + (w / 2)
                        nose_x_offset = abs(no[0] - face_center_x)
                        if nose_x_offset > (w / 2) * 0.4: return True
                return False
            except: return True

        db = get_db()
        bucket = storage.bucket(bucket_name)
        blob = bucket.blob(file_path)
        blob.download_to_filename(temp_local_path)

        if os.path.getsize(temp_local_path) == 0: return

        def normalize_embedding(emb):
            vec = np.array(emb)
            norm = np.linalg.norm(vec)
            return (vec / norm).tolist() if norm > 0 else None

        def calculate_distance(emb1, emb2):
            return 1.0 - (np.dot(emb1, emb2) / (np.linalg.norm(emb1) * np.linalg.norm(emb2)))

        # [Mode 1] 얼굴 등록
        if "source/user_face/" in file_path:
            # (기존 등록 로직과 동일)
            try:
                faces = DeepFace.extract_faces(img_path=temp_local_path, detector_backend='retinaface', enforce_detection=True, align=True)
                if not faces: return
                max_face = max(faces, key=lambda f: f['facial_area']['w'] * f['facial_area']['h'])
                face_img = (max_face['face'] * 255).astype(np.uint8)
                face_bgr = cv2.cvtColor(face_img, cv2.COLOR_RGB2BGR)

                res = DeepFace.represent(img_path=face_bgr, model_name=ACTIVE_MODELS[0], detector_backend='skip')
                norm_vec = normalize_embedding(res[0]["embedding"])

                if norm_vec:
                    doc_ref = db.collection("users").document(uid).collection("user_face").document("my_face_profile")
                    enc_vec = encrypt_vector(norm_vec)
                    ts = datetime.now().strftime("%Y%m%d%H%M%S")
                    doc_ref.set({
                        "name": "Me",
                        "updated_at": datetime.now(),
                        "embeddings": {ACTIVE_MODELS[0]: {f"v_add_{ts}": enc_vec}}
                    }, merge=True)
                    blob.delete()
            except Exception as e: print(f"등록 실패: {e}")
            return

        # [Mode 2] 사진 분석
        elif "source/images/" in file_path:
            print(f"▶ [Mode: Analysis] 사용자({uid}) 사진 분석 시작")

            # [New] 사용자 본명 가져오기 (Me -> 실명 변환용)
            user_real_name = "Me"
            try:
                user_doc = db.collection("users").document(uid).get()
                if user_doc.exists:
                    user_real_name = user_doc.to_dict().get("name", "Me")
            except: pass

            # [중복 방지] 해당 파일 경로로 미리 처리된 unknown_faces 데이터 삭제
            try:
                dup_docs = db.collection("users").document(uid).collection("unknown_faces") \
                    .where(filter=firestore.FieldFilter("source_file_path", "==", file_path)).stream()

                dup_batch = db.batch()
                dup_count = 0
                for d in dup_docs:
                    dup_batch.delete(d.reference)
                    dup_count += 1

                if dup_count > 0:
                    dup_batch.commit()
                    print(f"🧹 기존 분석 데이터 {dup_count}건 삭제 완료 (중복 방지)")
            except Exception as e:
                print(f"⚠️ 중복 데이터 정리 중 에러 (계속 진행): {e}")

            known_map = {model: {} for model in ACTIVE_MODELS}

            my_faces = db.collection("users").document(uid).collection("user_face").stream()
            other_faces = db.collection("users").document(uid).collection("other_face").stream()
            cluster_suggestions = db.collection("users").document(uid).collection("cluster_suggestions").stream()

            def load_embeddings(docs, label_field='name', default_label='Unknown', is_suggestion=False):
                for doc in docs:
                    data = doc.to_dict()
                    name = data.get(label_field, default_label)
                    if is_suggestion: name = data.get('group_id', default_label)

                    if 'representative_embedding' in data:
                        vec = decrypt_vector(data['representative_embedding'])
                        if vec: known_map[ACTIVE_MODELS[0]].setdefault(name, []).append(vec)

                    if 'embeddings' in data and isinstance(data['embeddings'], dict):
                        for model, content in data['embeddings'].items():
                            if model in known_map:
                                if isinstance(content, dict):
                                    for val in content.values():
                                        vec = decrypt_vector(val) if isinstance(val, str) else val
                                        if vec: known_map[model].setdefault(name, []).append(vec)

            load_embeddings(my_faces, 'name', 'Me')
            load_embeddings(other_faces, 'name')
            load_embeddings(cluster_suggestions, 'group_id', is_suggestion=True)

            try:
                faces = DeepFace.extract_faces(img_path=temp_local_path, detector_backend='retinaface', enforce_detection=False, align=True)
            except: faces = []

            results = []
            for face_obj in faces:
                # [로컬 동기화] 필터링
                if is_side_or_back_face(face_obj): continue

                face_img = (face_obj['face'] * 255).astype(np.uint8)
                face_bgr = cv2.cvtColor(face_img, cv2.COLOR_RGB2BGR)
                face_area = face_obj['facial_area']['w'] * face_obj['facial_area']['h']

                if face_area < 900: continue
                if face_area < 5000:
                    face_bgr = cv2.resize(face_bgr, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)

                if is_blurry(face_bgr, threshold=30): continue

                embs = {}
                try:
                    res = DeepFace.represent(img_path=face_bgr, model_name=ACTIVE_MODELS[0], detector_backend='skip')
                    embs[ACTIVE_MODELS[0]] = normalize_embedding(res[0]["embedding"])
                except: pass

                best_name = "Unknown"
                min_dist = 2.0
                target_model = ACTIVE_MODELS[0]

                if target_model in embs and target_model in known_map:
                    target_emb = embs[target_model]
                    if target_emb:
                        for name, db_vecs in known_map[target_model].items():
                            for db_vec in db_vecs:
                                d = calculate_distance(target_emb, db_vec)
                                if d < min_dist:
                                    min_dist = d
                                    best_name = name

                if min_dist > THRESHOLDS.get(target_model, 0.4): best_name = "Unknown"

                results.append({"name": best_name, "box": face_obj['facial_area']})

                if best_name == "Unknown":
                    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                    fname = f"unknown_{timestamp}.jpg"
                    # [수정] root_folder 변수 사용하여 원본 경로 구조(Users/users) 유지
                    save_path = f"{root_folder}/{uid}/source/unknown_faces/{fname}"
                    tpath = f"/tmp/{fname}"
                    cv2.imwrite(tpath, face_bgr)

                    try:
                        ublob = bucket.blob(save_path)
                        ublob.upload_from_filename(tpath)

                        # [중요] Blur Score 계산 및 저장
                        gray_check = cv2.cvtColor(face_bgr, cv2.COLOR_BGR2GRAY)
                        blur_score = cv2.Laplacian(gray_check, cv2.CV_64F).var()

                        db.collection("users").document(uid).collection("unknown_faces").add({
                            "image_url": ublob.public_url,
                            "source_file_path": file_path,
                            "storage_path": save_path,
                            "created_at": datetime.now(),
                            "is_processed": False,
                            "group_id": None,
                            "face_area": face_area,
                            "blur_score": blur_score, # 저장!
                            "embeddings": {k: encrypt_vector(v) for k,v in embs.items() if v}
                        })
                        os.remove(tpath)
                    except Exception as e: print(f"Save Error: {e}")

            # Gemini 분석
            detected_names = []
            for r in results:
                n = r['name']
                if n == 'Unknown': continue
                if n == 'Me': n = user_real_name
                detected_names.append(n)
            detected_names = list(set(detected_names))

            # KST 시간 설정 (UTC+9)
            kst = timezone(timedelta(hours=9))
            capture_date = datetime.now(kst)

            gemini_analysis = analyze_image_with_gemini(temp_local_path, detected_names)

            # Gemini 분석 실패(에러) 시 빈 값으로 처리
            if isinstance(gemini_analysis, dict) and ("error" in gemini_analysis):
                gemini_analysis = {}

            # Gemini의 when을 업로드 시간으로 덮어쓰기
            if isinstance(gemini_analysis, dict):
                gemini_analysis["when"] = capture_date.strftime("%Y년 %m월 %d일")

            log_entry = {
                "media_type": "image",
                "image_url": f"gs://{bucket_name}/{file_path}",
                "file_path": file_path,
                "names": detected_names,
                "how_detail": gemini_analysis,
                "timestamp": capture_date.isoformat(),
                "analyzed_at": datetime.now(kst).isoformat()
            }

            daily_ref = db.collection("users").document(uid).collection("daily_logs").document(capture_date.strftime("%Y-%m-%d"))
            daily_ref.set({
                "logs": firestore.ArrayUnion([encrypt_data(log_entry)]),
                "last_updated": datetime.now(kst)
            }, merge=True)
            print("✅ 분석 및 저장 완료")

    except Exception as e:
        print(f"Error: {e}")
        traceback.print_exc()
    finally:
        if os.path.exists(temp_local_path):
            try: os.remove(temp_local_path)
            except: pass

# ---------------------------------------------------------
# [Trigger 2] 매일 밤 클러스터링 (로컬 로직 완벽 이식)
# ---------------------------------------------------------
@scheduler_fn.on_schedule(schedule="00 18 * * *", memory=MemoryOption.GB_4, region="us-central1", timezone="Asia/Seoul")
def daily_cluster(event: scheduler_fn.ScheduledEvent) -> None:
    print("🚀 [Cloud Function] 사용자별 클러스터링 (품질 기반) 시작")

    import numpy as np
    from sklearn.cluster import DBSCAN
    from scipy.spatial.distance import pdist

    # [설정] 로컬 스크립트와 동일
    DBSCAN_EPS = 0.40
    MIN_SAMPLES = 2

    QUALITY_CONFIG = {
        "max_distance_std_trash": 0.22,
        "min_blur_trash": 20.0,
        "min_blur_good": 35.0 # 재활용 기준
    }

    # [Helper] 통계 계산
    def calc_stats(vectors, blur_scores):
        n = len(vectors)
        if n < 2:
            avg_dist = 0.0
            std_dist = 0.0
        else:
            dists = pdist(vectors, metric="cosine")
            avg_dist = float(np.mean(dists))
            std_dist = float(np.std(dists))

        valid_blurs = [b for b in blur_scores if b is not None]
        avg_blur = float(np.mean(valid_blurs)) if valid_blurs else 0.0
        return avg_dist, std_dist, avg_blur

    db = get_db()
    users = db.collection("users").stream()

    for user_doc in users:
        uid = user_doc.id

        # 1. 처리 대기 중인 Unknown 데이터 로드
        unknowns_ref = db.collection("users").document(uid).collection("unknown_faces")
        docs = unknowns_ref.where(filter=firestore.FieldFilter('is_processed', '==', False)).stream()

        doc_data_list = []
        vectors = []

        for doc in docs:
            data = doc.to_dict()
            if data.get('face_area', 0) < 900: continue

            if 'embeddings' in data and 'ArcFace' in data['embeddings']:
                val = data['embeddings']['ArcFace']
                vec = decrypt_vector(val) if isinstance(val, str) else val
                if vec:
                    doc_data_list.append({
                        'id': doc.id,
                        'ref': unknowns_ref.document(doc.id),
                        'vec': vec,
                        'area': data.get('face_area', 0),
                        'blur': data.get('blur_score', 0.0), # 저장된 blur 사용
                        'url': data.get('image_url', ''),
                        'source_path': data.get('source_file_path', ''),
                        'storage_path': data.get('storage_path', '')
                    })
                    vectors.append(vec)

        if len(vectors) < MIN_SAMPLES: continue

        # 2. DBSCAN 수행
        try:
            X = np.array(vectors)
            clustering = DBSCAN(eps=DBSCAN_EPS, min_samples=MIN_SAMPLES, metric='cosine').fit(X)

            batch = db.batch()
            batch_count = 0
            ts = datetime.now().strftime('%Y%m%d')

            # 그룹핑
            groups = {}
            noise_items = []

            for i, label in enumerate(clustering.labels_):
                if label == -1:
                    noise_items.append(doc_data_list[i])
                else:
                    if label not in groups: groups[label] = []
                    groups[label].append(doc_data_list[i])

            # 3. 그룹 품질 평가 및 처리
            groups_to_create = []

            for label, items in groups.items():
                vecs = [it['vec'] for it in items]
                blurs = [it['blur'] for it in items]

                avg_dist, std_dist, avg_blur = calc_stats(vecs, blurs)
                group_key = f"group_{ts}_{label}"
                is_trash = False

                # [Trash 판정] 흐릿하거나 이질적이면 Trash
                if avg_blur < QUALITY_CONFIG["min_blur_trash"]: is_trash = True
                elif std_dist > QUALITY_CONFIG["max_distance_std_trash"]: is_trash = True

                # DB 업데이트
                for item in items:
                    update_payload = {
                        'is_processed': True,
                        'group_id': "TRASH" if is_trash else group_key
                    }
                    batch.update(item['ref'], update_payload)
                    batch_count += 1

                if not is_trash:
                    mean_vec = np.mean(vecs, axis=0)
                    norm = np.linalg.norm(mean_vec)
                    rep_vec = (mean_vec / norm).tolist() if norm > 0 else None
                    groups_to_create.append({
                        'group_id': group_key,
                        'items': items,
                        'count': len(items),
                        'rep_vec': rep_vec
                    })

            # 4. 노이즈(분류 안된 얼굴) 처리 (여기가 핵심!)
            # 로컬과 동일하게: 화질 좋으면 남겨두고(Recycle), 나쁘면 Trash
            trash_storage_paths = []  # Storage 삭제 대상 수집

            for item in noise_items:
                blur = item['blur']
                if blur >= QUALITY_CONFIG["min_blur_good"]:
                    # 화질 좋음 -> 건드리지 않음 (is_processed=False 유지)
                    # 다음 클러스터링 때 새로운 사진과 매칭될 수 있음
                    continue
                else:
                    # 화질 나쁨 -> Trash 처리 (영구 제외)
                    batch.update(item['ref'], {'is_processed': True, 'group_id': "TRASH"})
                    batch_count += 1
                    # Storage 삭제 대상 추가
                    if item.get('storage_path'):
                        trash_storage_paths.append(item['storage_path'])

            if batch_count >= 400:
                batch.commit()
                batch = db.batch()
                batch_count = 0
            if batch_count > 0: batch.commit()

            # 4-1. TRASH 이미지 Storage에서 삭제 (개인정보 최소화)
            bucket = storage.bucket(BUCKET_NAME)
            trash_deleted = 0
            for path in trash_storage_paths:
                try:
                    bucket.blob(path).delete()
                    trash_deleted += 1
                except Exception as e:
                    print(f"⚠️ TRASH 이미지 삭제 실패: {path} - {e}")
            if trash_deleted > 0:
                print(f"🗑️ TRASH 이미지 {trash_deleted}개 Storage에서 삭제")

            # 5. Suggestion 생성
            suggestions_ref = db.collection("users").document(uid).collection("cluster_suggestions")
            bucket = storage.bucket(BUCKET_NAME)

            for g_info in groups_to_create:
                if not g_info['rep_vec']: continue

                encrypted_rep_vec = encrypt_vector(g_info['rep_vec'])
                items = g_info['items']

                best_item = max(items, key=lambda x: x['area'])
                final_thumb_url = best_item['url']

                # 썸네일 별도 저장 (Users 폴더에 저장)
                if best_item.get('storage_path'):
                    try:
                        src_blob = bucket.blob(best_item['storage_path'])
                        new_thumb_path = f"Users/{uid}/result/faces/{g_info['group_id']}_thumb.jpg"
                        bucket.copy_blob(src_blob, bucket, new_thumb_path)
                        # [변경] 앱에서 gs:// 주소를 로드하지 못하므로, 복사는 하되 URL은 원본 HTTP URL(best_item['url'])을 유지하거나
                        # public_url을 구해야 합니다. 여기선 안전하게 원본 HTTP URL 사용 (복사본은 백업용으로 유지)
                        # final_thumb_url = f"gs://{BUCKET_NAME}/{new_thumb_path}"
                    except: pass

                # [변경] 샘플 이미지도 gs:// 대신 HTTP 주소 사용
                sample_urls = [it['url'] for it in items[:5]]
                members_preview = [{'id': it['id'], 'face_url': it['url']} for it in items]

                suggestions_ref.document(g_info['group_id']).set({
                    "cluster_id": g_info['group_id'],
                    "group_id": g_info['group_id'],
                    "status": "UNLABELED",
                    "thumbnail_url": final_thumb_url,
                    "sample_image_urls": sample_urls,
                    "members": members_preview,
                    "photo_count": g_info['count'],
                    "created_at": datetime.now(),
                    "representative_embedding": encrypted_rep_vec
                })
                print(f"  ✨ 제안 생성: {g_info['group_id']} ({g_info['count']}장)")

        except Exception as e:
            print(f"  ⚠️ 사용자 [{uid}] 클러스터링 에러: {e}")
            traceback.print_exc()

    print("✅ 클러스터링 완료")

# ---------------------------------------------------------
# [Callable] 제안 거절 (그룹 해체 -> 대기열 복귀)
# ---------------------------------------------------------
@https_fn.on_call(region="us-central1", memory=MemoryOption.GB_1)
def reject_cluster_suggestion(req: https_fn.CallableRequest):
    data = req.data
    uid = data.get("uid") or (req.auth.uid if req.auth else None)
    group_id = data.get("group_id")

    if not uid or not group_id: return {"error": "Missing info"}

    print(f"🚫 [Reject] 그룹({group_id}) 해체 요청")
    db = get_db()

    # 1. 제안 삭제
    db.collection("users").document(uid).collection("cluster_suggestions").document(group_id).delete()

    # 2. 썸네일 이미지 삭제
    try:
        bucket = storage.bucket(BUCKET_NAME)
        thumb_path = f"Users/{uid}/result/faces/{group_id}_thumb.jpg"
        bucket.blob(thumb_path).delete()
        print(f"🗑️ 썸네일 삭제: {thumb_path}")
    except Exception as e:
        print(f"⚠️ 썸네일 삭제 실패 (무시): {e}")

    # 3. 사진들 대기열 복귀 (is_processed=False)
    unknowns = db.collection("users").document(uid).collection("unknown_faces")
    docs = unknowns.where(filter=firestore.FieldFilter('group_id', '==', group_id)).stream()

    batch = db.batch()
    c = 0
    for doc in docs:
        batch.update(doc.reference, {'is_processed': False, 'group_id': None})
        c += 1
    batch.commit()

    return {"success": True, "message": f"{c}장 복귀 완료"}

# ---------------------------------------------------------
# [Callable] 제안 확정 (이름 등록 + 제외 처리)
# ---------------------------------------------------------
@https_fn.on_call(region="us-central1", memory=MemoryOption.GB_1)
def register_face_label(req: https_fn.CallableRequest):
    data = req.data
    uid = data.get("uid") or (req.auth.uid if req.auth else None)
    group_id = data.get("group_id")
    new_name = data.get("name")
    exclude_ids = data.get("exclude_face_ids", [])

    if not uid or not group_id or not new_name: return {"error": "Missing info"}

    print(f"📝 [Labeling] {group_id} -> {new_name}")
    db = get_db()
    user_root = db.collection("users").document(uid)

    # 1. 대표 벡터 확인
    s_doc = user_root.collection("cluster_suggestions").document(group_id).get()
    if not s_doc.exists: return {"error": "Group not found"}

    # 2. 대상 사진 로드
    unknowns_ref = user_root.collection("unknown_faces")
    doc_list = list(unknowns_ref.where(filter=firestore.FieldFilter('group_id', '==', group_id)).stream())

    import numpy as np
    valid_vectors = []

    for doc in doc_list:
        if doc.id in exclude_ids: continue
        d = doc.to_dict()
        if 'embeddings' in d and 'ArcFace' in d['embeddings']:
            val = d['embeddings']['ArcFace']
            vec = decrypt_vector(val) if isinstance(val, str) else val
            if vec: valid_vectors.append(vec)

    final_rep_vec_enc = None
    if len(valid_vectors) > 0:
        mean_vec = np.mean(valid_vectors, axis=0)
        norm = np.linalg.norm(mean_vec)
        if norm > 0:
            final_rep_vec_enc = encrypt_vector((mean_vec / norm).tolist())
        else:
            final_rep_vec_enc = s_doc.to_dict().get('representative_embedding')
    else:
        final_rep_vec_enc = s_doc.to_dict().get('representative_embedding')

    # 3. other_face 등록
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    target_ref = user_root.collection("other_face").document(new_name)
    target_ref.set({
        "name": new_name,
        "updated_at": datetime.now(),
        "embeddings": {
            ACTIVE_MODELS[0]: {f"v_cls_{ts}_rep": final_rep_vec_enc}
        }
    }, merge=True)

    # 4. 정리 (Firestore + Storage 이미지 삭제)
    batch = db.batch()
    batch.delete(s_doc.reference)

    bucket = storage.bucket(BUCKET_NAME)
    deleted_images = 0

    # 썸네일 이미지 삭제
    try:
        thumb_path = f"Users/{uid}/result/faces/{group_id}_thumb.jpg"
        bucket.blob(thumb_path).delete()
        print(f"🗑️ 썸네일 삭제: {thumb_path}")
    except Exception as e:
        print(f"⚠️ 썸네일 삭제 실패 (무시): {e}")

    for doc in doc_list:
        doc_data = doc.to_dict()

        if doc.id in exclude_ids:
            # 제외된 사진은 대기열로 복귀 (Recycle) - 로컬 로직과 동일 철학
            batch.update(doc.reference, {'is_processed': False, 'group_id': None})
        else:
            # 확정된 사진: 메타데이터 + Storage 이미지 모두 삭제 (개인정보 최소화)
            batch.delete(doc.reference)

            # Storage에서 얼굴 이미지 파일 삭제
            storage_path = doc_data.get('storage_path')
            if storage_path:
                try:
                    bucket.blob(storage_path).delete()
                    deleted_images += 1
                except Exception as e:
                    print(f"⚠️ 이미지 삭제 실패: {storage_path} - {e}")

    batch.commit()

    print(f"✅ {new_name}님 등록 완료 (이미지 {deleted_images}개 삭제)")
    return {"success": True, "message": f"{new_name}님 등록 완료"}
