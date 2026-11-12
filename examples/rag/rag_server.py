from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
import os
import firebase_admin
from firebase_admin import credentials, firestore
import vertexai
from vertexai.language_models import TextEmbeddingModel
from vertexai.generative_models import GenerativeModel
import numpy as np
from contextlib import asynccontextmanager
import tkinter as tk
from tkinter import filedialog

# --- 설정 ---
PROJECT_ID = os.getenv("GCLOUD_PROJECT")
LOCATION = "us-central1"
KEY_FILE_PATH = "serviceAccountKey.json" # 서버 실행 위치에 키 파일이 있다고 가정

# --- 전역 변수 ---
db = None
embedding_model = None
generative_model = None
# 캐싱된 데이터
cached_doc_ids = []
cached_embedding_matrix = None

def select_file(title, filetypes):
    """파일 선택 대화상자를 엽니다."""
    try:
        root = tk.Tk()
        root.withdraw()
        root.lift()
        root.attributes('-topmost', True)
        root.after_idle(root.attributes, '-topmost', False)
        file_path = filedialog.askopenfilename(title=title, filetypes=filetypes)
        root.destroy()
        return file_path
    except Exception:
        return None

@asynccontextmanager
async def lifespan(app: FastAPI):
    """서버 수명 주기 관리 (시작/종료)"""
    # Startup
    try:
        initialize_services()
    except Exception as e:
        print(f"❌ 서버 시작 중 오류 발생: {e}")
    yield
    # Shutdown (필요 시 리소스 정리)

app = FastAPI(title="AI Memory & Diary Server", lifespan=lifespan)

# --- 데이터 모델 ---
class QueryRequest(BaseModel):
    query: str

class DiaryRequest(BaseModel):
    situation: str

# --- 서비스 로직 ---

def load_vector_cache():
    """Firestore에서 모든 벡터를 가져와 메모리에 캐싱합니다."""
    global cached_doc_ids, cached_embedding_matrix

    print("⏳ 벡터 데이터 캐싱 중...")
    try:
        # embedding 필드만 가져와서 데이터 전송량 최소화
        docs = db.collection("vectors").select(["embedding"]).stream()

        vectors = []
        ids = []

        for doc in docs:
            data = doc.to_dict()
            if "embedding" in data:
                vectors.append(data["embedding"])
                ids.append(doc.id)

        if vectors:
            # Numpy 행렬로 변환
            matrix = np.array(vectors)
            # 코사인 유사도 계산을 위한 정규화 (L2 Norm)
            norm = np.linalg.norm(matrix, axis=1, keepdims=True)
            # 0으로 나누기 방지
            cached_embedding_matrix = matrix / (norm + 1e-10)
            cached_doc_ids = ids
            print(f"✅ {len(vectors)}개의 기억 데이터를 메모리에 로드했습니다.")
        else:
            print("⚠️ 저장된 기억 데이터가 없습니다.")

    except Exception as e:
        print(f"❌ 캐싱 중 오류 발생: {e}")

def initialize_services():
    """Firebase 및 Vertex AI 서비스를 초기화합니다."""
    global db, embedding_model, generative_model

    print("🔄 서비스 연결 중...")

    try:
        if not firebase_admin._apps:
            # 1. 환경 변수 확인
            if os.getenv("GOOGLE_APPLICATION_CREDENTIALS"):
                firebase_admin.initialize_app()
                print("✅ Firebase 연결 성공 (환경 변수 사용)")
            # 2. 키 파일 확인
            elif os.path.exists(KEY_FILE_PATH):
                os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = KEY_FILE_PATH
                cred = credentials.Certificate(KEY_FILE_PATH)
                firebase_admin.initialize_app(cred)
                print(f"✅ Firebase 연결 성공 ({KEY_FILE_PATH} 사용)")
            else:
                print("⚠️ 인증 정보가 필요합니다.")
                key_path = select_file("Firebase 서비스 계정 키 파일 선택", [("JSON", "*.json")])

                if key_path:
                    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = key_path
                    cred = credentials.Certificate(key_path)
                    firebase_admin.initialize_app(cred)
                    print(f"✅ Firebase 연결 성공 ({key_path} 사용)")
                else:
                    # 로컬 개발 환경 등에서 이미 인증된 경우
                    firebase_admin.initialize_app()
                    print("✅ Firebase 연결 성공 (기본 인증 사용)")

        db = firestore.client()
    except Exception as e:
        print(f"❌ Firebase 초기화 실패: {e}")
        raise e

    try:
        vertexai.init(project=PROJECT_ID, location=LOCATION)
        embedding_model = TextEmbeddingModel.from_pretrained("text-embedding-004")

        try:
            generative_model = GenerativeModel("gemini-2.5-flash")
            print("✅ gemini-2.5-flash 모델 로드 성공")
        except Exception:
            print("⚠️ gemini-2.5-flash 모델 로드 실패. gemini-2.5-pro 모델로 시도합니다.")
            generative_model = GenerativeModel("gemini-2.5-pro")
            print("✅ gemini-2.5-pro 모델 로드 성공")

    except Exception as e:
        print(f"❌ Vertex AI 초기화 실패: {e}")
        raise e

    # 서비스 초기화 후 벡터 캐싱 실행
    load_vector_cache()

def generate_embedding(text):
    if not text: return None
    text = text.replace("\n", " ")
    return embedding_model.get_embeddings([text])[0].values

# --- 기능 함수 ---

def search_and_answer_logic(query):
    print(f"\n🔍 질문 분석 중: {query}")

    # 1. 질문 벡터화
    query_vec = generate_embedding(query)
    if query_vec is None:
        return "질문을 이해하지 못했습니다."

    # 2. 고속 유사도 검색
    if cached_embedding_matrix is None or len(cached_doc_ids) == 0:
        return "기억 데이터가 로드되지 않았습니다."

    q_vec = np.array(query_vec)
    q_norm = np.linalg.norm(q_vec)
    q_vec = q_vec / (q_norm + 1e-10)

    similarities = np.dot(cached_embedding_matrix, q_vec)
    top_k_indices = np.argsort(similarities)[-5:][::-1]

    top_docs = []
    for idx in top_k_indices:
        score = similarities[idx]
        if score < 0.3: continue

        doc_id = cached_doc_ids[idx]
        doc_snapshot = db.collection("vectors").document(doc_id).get()
        if doc_snapshot.exists:
            top_docs.append((score, doc_snapshot.to_dict()))

    if not top_docs:
        return "죄송합니다. 그 날의 기록을 찾을 수 없거나, 관련 내용을 기억하지 못하고 있습니다."

    # 3. 프롬프트 구성
    context_text = ""
    for i, (score, doc) in enumerate(top_docs):
        timestamp = doc.get('timestamp', '날짜 미상')
        content = doc.get('vectorized_text') or doc.get('content') or doc.get('diary') or doc.get('summary') or str(doc)
        context_text += f"[{i+1}] (유사도: {score:.2f}) 날짜: {timestamp}\n내용: {content}\n\n"

    prompt = f"""
    당신은 사용자의 소중한 기억을 되짚어주는 AI 비서입니다.
    아래 [관련 기록]은 사용자의 질문과 유사한 과거의 일기나 기록들입니다.
    이 기록들을 바탕으로 사용자의 [질문]에 대해 정확하고 자연스럽게 답변해주세요.

    - 답변은 한국어로 작성해주세요.
    - 답변은 "사용자님은 ~ 하셨습니다" 와 같은 정중한 어조를 사용하세요.
    - 기록에 없는 내용은 지어내지 말것. 모를 경우 "기억하지 못하고 있습니다"라고 답변하세요.

    [관련 기록]
    {context_text}

    [질문]
    {query}

    [답변]
    """

    response = generative_model.generate_content(prompt)
    return response.text

def find_similar_diary_sample(current_situation):
    if not current_situation:
        return None, 0

    query_vec = generate_embedding(current_situation)
    if query_vec is None:
        return None, 0

    if cached_embedding_matrix is None or len(cached_doc_ids) == 0:
        return None, 0

    q_vec = np.array(query_vec)
    q_norm = np.linalg.norm(q_vec)
    q_vec = q_vec / (q_norm + 1e-10)

    similarities = np.dot(cached_embedding_matrix, q_vec)
    best_idx = np.argmax(similarities)
    best_score = similarities[best_idx]

    if best_score < 0.4:
        return None, 0

    doc_id = cached_doc_ids[best_idx]
    doc_snapshot = db.collection("vectors").document(doc_id).get()
    if doc_snapshot.exists:
        data = doc_snapshot.to_dict()
        content = data.get('diary') or data.get('content') or data.get('vectorized_text')
        return content, best_score

    return None, 0

def write_diary_logic(current_situation):
    print(f"📝 일기 작성 요청 분석 중: {current_situation[:30]}...")

    sample_diary, score = find_similar_diary_sample(current_situation)

    prompt = """
당신은 사용자의 하루를 기록해주는 감성적인 AI 일기 작가입니다.
사용자가 입력한 [오늘의 상황]을 바탕으로, 한 편의 자연스러운 일기를 작성해주세요.
"""

    if sample_diary:
        print(f"💡 유사한 과거 기록 발견 (유사도: {score:.2f}) - 스타일을 참고합니다.")
        prompt += f"""
아래 [스타일 참고용 과거 일기]는 사용자가 과거에 썼던 유사한 상황의 일기입니다.
이 예시의 **문체, 어조, 감정 표현 방식**을 참고하여 일기를 작성하세요.
단, 내용은 [오늘의 상황]에 맞춰서 새롭게 써야 합니다. 과거 내용을 그대로 베끼지 마세요.

[스타일 참고용 과거 일기]
{sample_diary}
"""
    else:
        print("ℹ️ 참고할 만한 유사한 과거 기록이 없어, 기본 스타일로 작성합니다.")
        prompt += """
특별히 참고할 과거 기록이 없으므로, 보편적으로 따뜻하고 공감가는 어조로 작성해주세요.
"""

    prompt += f"""
[오늘의 상황]
{current_situation}

[작성된 일기]
"""

    response = generative_model.generate_content(prompt)
    return response.text

# --- API 엔드포인트 ---

@app.get("/")
def read_root():
    return {"status": "online", "message": "AI Memory & Diary Server is running"}

@app.post("/query")
async def query_endpoint(request: QueryRequest):
    """질문에 대한 답변을 생성합니다."""
    try:
        answer = search_and_answer_logic(request.query)
        return {"answer": answer}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/diary")
async def diary_endpoint(request: DiaryRequest):
    """상황에 맞는 일기를 작성합니다."""
    try:
        diary = write_diary_logic(request.situation)
        return {"diary": diary}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/refresh")
async def refresh_cache():
    """벡터 캐시를 수동으로 새로고침합니다."""
    try:
        load_vector_cache()
        return {"message": "Cache refreshed successfully", "count": len(cached_doc_ids)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    # 외부 접속 허용 (0.0.0.0)
    uvicorn.run(app, host="0.0.0.0", port=8000)
