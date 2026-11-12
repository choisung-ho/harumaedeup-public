# 1. Python 3.11 베이스 이미지 사용
FROM python:3.11-slim

# 2. 오디오 처리를 위한 시스템 필수 패키지 설치 (ffmpeg, libsndfile, git)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 \
    ffmpeg \
    git \
    && rm -rf /var/lib/apt/lists/*

# 3. 작업 디렉토리 설정
WORKDIR /app

# ★ [Cloud Run 호환] 캐시 디렉토리 환경변수 설정
# Cloud Run은 /tmp만 쓰기 가능하므로 모든 캐시를 /tmp로 지정
ENV HF_HOME=/tmp/model_cache/huggingface
ENV TRANSFORMERS_CACHE=/tmp/model_cache/transformers
ENV TORCH_HOME=/tmp/model_cache/torch
ENV XDG_CACHE_HOME=/tmp/model_cache
ENV HF_HUB_DISABLE_SYMLINKS=1
ENV PYTHONUNBUFFERED=1

# 4. 의존성 파일 복사 및 설치 (레이어 캐싱 활용)
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# 5. 소스 코드 및 인증 키 복사
COPY . .

# 6. 포트 설정 (Cloud Run 기본 포트)
ENV PORT=8080

# 7. 서버 실행 명령
# --timeout-keep-alive 300: 긴 STT 요청(~120초) 시 연결 유지
# --workers 1: Cloud Run은 컨테이너당 concurrency로 관리하므로 1 유지
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--timeout-keep-alive", "300"]
