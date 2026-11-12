import json
import os
import base64
import re
import tempfile
from datetime import datetime
from firebase_functions import storage_fn, pubsub_fn, firestore_fn, https_fn, options
from firebase_admin import storage, initialize_app
import firebase_admin


if not firebase_admin._apps:
    initialize_app(options={
        'projectId': os.getenv("GCLOUD_PROJECT"),
        'storageBucket': os.getenv("STORAGE_BUCKET_NAME")
    })

PROJECT_ID = os.environ.get("GCLOUD_PROJECT")

# --------------------------------------------------------------------------------
# 1. [Router] 파일 업로드 감지 -> Pub/Sub 전송
# --------------------------------------------------------------------------------
@storage_fn.on_object_finalized(region="us-central1", memory=options.MemoryOption.GB_1)
def route_file_event(event: storage_fn.CloudEvent[storage_fn.StorageObjectData]):
    # [Lazy Import] 무거운 라이브러리는 함수 안에서!
    from google.cloud import pubsub_v1

    publisher = pubsub_v1.PublisherClient()
    bucket_name = event.data.bucket
    file_path = event.data.name

    parts = file_path.split("/")
    if len(parts) < 5 or parts[0] != "Users" or parts[2] != "source":
        print(f"⚠️ [Skip] 경로 불일치: {file_path}")
        return

    user_id = parts[1]
    category = parts[3]
    filename = parts[4]

    match = re.search(r"(\d{4}-\d{2}-\d{2})", filename)
    date_str = match.group(1) if match else datetime.now().strftime("%Y-%m-%d")

    message_data = {
        "bucket": bucket_name,
        "filePath": file_path,
        "userId": user_id,
        "date": date_str,
        "category": category
    }

    data_bytes = json.dumps(message_data).encode("utf-8")
    topic_id = None

    if category == "locations":
        topic_id = "topic-analyze-location"
    elif category in ["calls", "sms_logs"]:
        topic_id = "topic-analyze-call_sms"

    if topic_id:
        topic_path = publisher.topic_path(PROJECT_ID, topic_id)
        future = publisher.publish(topic_path, data_bytes)
        print(f"🚀 [Router] {category} -> {topic_id} 발송 (User: {user_id})")

# --------------------------------------------------------------------------------
# 2. [Worker] 위치 분석 워커
# --------------------------------------------------------------------------------
@pubsub_fn.on_message_published(
    topic="topic-analyze-location",
    region="us-central1",
    timeout_sec=300,
    memory=options.MemoryOption.MB_512
)
def process_location_analysis(event: pubsub_fn.CloudEvent[pubsub_fn.MessagePublishedData]):
    from location_analysis import run_location_analysis # [Lazy Import]

    try:
        message_data_str = base64.b64decode(event.data.message.data).decode("utf-8")
        data = json.loads(message_data_str)

        print(f"📍 [Worker] 위치 분석 요청 수신: {data['userId']}")

        run_location_analysis(
            bucket_name=data['bucket'],
            file_path=data['filePath'],
            user_id=data['userId'],
            date_str=data.get('date')
        )
        print("✅ [Worker] 분석 완료")
    except Exception as e:
        print(f"❌ [Worker Error] {e}")

# --------------------------------------------------------------------------------
# 3. [Worker] 일기 자동 생성 트리거
# --------------------------------------------------------------------------------
@firestore_fn.on_document_written(
    document="users/{user_id}/daily_logs/{date_id}",
    region="us-central1",
    memory=options.MemoryOption.GB_1,
    timeout_sec=540
)
def trigger_diary_generation(event: firestore_fn.Event[firestore_fn.Change]):
    from diary_processor import process_diary_generation # [Lazy Import]

    user_id = event.params["user_id"]
    date_id = event.params["date_id"]

    if not event.data.after:
        return

    # [무한 루프 방지]
    before_data = event.data.before.to_dict() if event.data.before else {}
    after_data = event.data.after.to_dict()
    logs_before = before_data.get('logs', []) + before_data.get('location_logs', [])
    logs_after = after_data.get('logs', []) + after_data.get('location_logs', [])

    if len(logs_before) == len(logs_after) and len(logs_after) > 0:
        print(f"🛑 [Skip] 로그 개수 변동 없음 ({len(logs_after)}개). 중복 실행 방지.")
        return

    print(f"🔔 [Trigger] 로그 업데이트 감지: {user_id} / {date_id}")

    try:
        process_diary_generation(user_id, date_id)
        print("✅ 일기 생성 프로세스 완료")
    except Exception as e:
        print(f"❌ 일기 생성 실패: {e}")
