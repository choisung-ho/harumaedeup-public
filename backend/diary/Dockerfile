# Dockerfile

# 1. 파이썬 3.11 이미지 사용
FROM python:3.11-slim

# 2. 작업 폴더 설정
WORKDIR /app

# 3. 필수 시스템 패키지 설치 (오디오 변환 등이 필요 없다면 생략 가능)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# 4. 의존성 파일 복사 및 설치
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 5. 소스 코드 복사
# (auth_app.py와 필요한 파일들을 복사합니다)
COPY auth_app.py .
# COPY serviceAccountKey.json .  <-- (선택) 클라우드 배포 시엔 자동 인증되므로 주석 처리 추천

# 6. 환경 변수 설정 (로그가 바로 보이게 함)
ENV PYTHONUNBUFFERED=1

# 7. 서버 실행 (FastAPI를 uvicorn으로 직접 실행)
# Cloud Run은 자동으로 $PORT 환경변수를 주입하므로 그것을 사용해야 함
CMD exec uvicorn auth_app:app --host 0.0.0.0 --port ${PORT:-8080}
