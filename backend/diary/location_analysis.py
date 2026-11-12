import os
import json
import math
import requests
import firebase_admin
from firebase_admin import firestore, storage
from datetime import datetime, timedelta

# [보안] 암호화 모듈 임포트
from utils.crypto_utils import CryptoManager

# 환경변수는 Cloud Functions 런타임이 .env에서 자동으로 로드합니다.
KAKAO_API_KEY = os.environ.get("KAKAO_API_KEY")

# 상수 설정
STAY_RADIUS = 100
STAY_TIME_MIN = 5
HOME_THRESHOLD = 50

# ==============================================================================
# [Core] 메인 실행 함수 (main.py에서 호출하는 진입점)
# ==============================================================================
def run_location_analysis(bucket_name, file_path, user_id, date_str):
    """
    Cloud Functions(main.py)에서 이 함수를 호출하여 분석을 시작합니다.
    """
    print(f"📍 [Logic] 위치 분석 시작: {user_id} / {date_str}")

    # 1. DB/Storage 클라이언트 초기화 (이미 초기화되어 있으면 패스)
    if not firebase_admin._apps:
        firebase_admin.initialize_app()

    db = firestore.client()
    bucket = storage.bucket(bucket_name)

    try:
        # 2. JSON 파일 다운로드
        blob = bucket.blob(file_path)
        json_bytes = blob.download_as_string()
        raw_logs = json.loads(json_bytes)

        # 3. 분석 실행
        analyze_logs(user_id, date_str, raw_logs, db)
        return "Success"

    except Exception as e:
        print(f"❌ [Logic Error] 분석 중 오류 발생: {e}")
        # 에러를 던져서 Cloud Functions 로그에 남게 함
        raise e

# ==============================================================================
# [Helper] 분석 알고리즘 (기존 로직 유지)
# ==============================================================================

def analyze_logs(user_id, date_str, raw_logs, db):
    if not raw_logs: return

    # 유저 집 정보 가져오기
    home_lat, home_lng = get_user_home_info(db, user_id)

    sorted_logs = []
    for log in raw_logs:
        try:
            ts = datetime.fromisoformat(log['timestamp'])
            sorted_logs.append({
                'lat': log['lat'], 'lng': log['lng'],
                'time': ts, 'time_str': ts.strftime("%H:%M:%S")
            })
        except: continue

    sorted_logs.sort(key=lambda x: x['time'])
    if not sorted_logs: return

    current_group = [sorted_logs[0]]
    final_places = []

    for i in range(1, len(sorted_logs)):
        prev = current_group[-1]
        curr = sorted_logs[i]

        dist = calculate_distance(prev['lat'], prev['lng'], curr['lat'], curr['lng'])

        if dist <= STAY_RADIUS:
            current_group.append(curr)
        else:
            process_group(current_group, final_places, home_lat, home_lng)
            current_group = [curr]

    process_group(current_group, final_places, home_lat, home_lng)

    # 1. 결과가 0개라도 확인하기 위해 로그 추가
    print(f"   📊 분석된 장소 개수: {len(final_places)}개")

    if final_places:
        optimized_places = merge_consecutive_logs(final_places)
        save_to_firestore(db, user_id, date_str, optimized_places)
    else:
        print(f"   💨 10분 이상 체류한 장소가 없어 저장을 건너뜁니다.")

        # [선택 사항] 테스트를 위해 강제로 빈 데이터라도 저장하고 싶다면 주석 해제하세요:
        # save_to_firestore(db, user_id, date_str, [])

# [핵심 수정] 저장 함수 업데이트
def save_to_firestore(db, user_id, date_str, places):
    try:
        encrypted_places = []
        for p in places:
            # ★ 암호화 적용
            enc_str = CryptoManager.encrypt_data(p)
            encrypted_places.append(enc_str)

        target_ref = db.collection("users").document(user_id).collection("daily_logs").document(date_str)

        # [변경 사항]
        # 1. 필드명: logs -> location_logs 로 변경 (통화/문자와 분리)
        # 2. 저장방식: ArrayUnion(추가) -> 리스트 직접 대입(덮어쓰기)
        #    이유: 원본 파일이 시간이 지날수록 내용이 늘어나면서 덮어씌워지므로,
        #          DB도 그 시점의 최신 분석 결과로 '교체'해야 중복이 안 생김.
        target_ref.set({
            "user_id": user_id,
            "date": date_str,
            "location_logs": encrypted_places, # ★ 여기가 핵심 변경 (ArrayUnion 제거)
            "last_updated": firestore.SERVER_TIMESTAMP
        }, merge=True) # merge=True 덕분에 기존 logs(통화/문자) 필드는 건드리지 않음

        print(f"   💾 [저장 완료] location_logs 필드 업데이트: {len(places)}건")
    except Exception as e:
        print(f"   ❌ DB 저장 실패: {e}")

# ... (아래는 계산 함수들 - 기존과 동일) ...

def calculate_distance(lat1, lon1, lat2, lon2):
    try:
        lat1, lon1, lat2, lon2 = float(lat1), float(lon1), float(lat2), float(lon2)
        R = 6371 * 1000
        dLat = math.radians(lat2 - lat1)
        dLon = math.radians(lon2 - lon1)
        a = math.sin(dLat/2) * math.sin(dLat/2) + \
            math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * \
            math.sin(dLon/2) * math.sin(dLon/2)
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        return R * c
    except: return 999999

def get_place_name(lat, lng):
    if not KAKAO_API_KEY: return "API키 없음", ""
    headers = {"Authorization": f"KakaoAK {KAKAO_API_KEY}"}
    try:
        geo_res = requests.get("https://dapi.kakao.com/v2/local/geo/coord2address.json",
                             headers=headers, params={"x": lng, "y": lat}).json()
        full_addr = ""
        if geo_res.get('meta', {}).get('total_count', 0) > 0:
            doc = geo_res['documents'][0]
            full_addr = doc['road_address']['address_name'] if doc['road_address'] else doc['address']['address_name']

        search_res = requests.get("https://dapi.kakao.com/v2/local/search/keyword.json",
                                headers=headers, params={"query": full_addr, "x": lng, "y": lat, "radius": 100}).json()
        place_name = full_addr
        if search_res.get('meta', {}).get('total_count', 0) > 0:
            place_name = search_res['documents'][0]['place_name']
        return full_addr, place_name
    except: return full_addr, ""

def get_user_home_info(db, user_id):
    try:
        doc = db.collection("users").document(user_id).get()
        if doc.exists:
            data = doc.to_dict()
            h_lat = data.get("homeLat")
            h_lng = data.get("homeLng")

            # 암호화된 좌표 복호화 시도
            if isinstance(h_lat, str):
                try: h_lat = float(CryptoManager.decrypt_data(h_lat))
                except: pass
            if isinstance(h_lng, str):
                try: h_lng = float(CryptoManager.decrypt_data(h_lng))
                except: pass

            if h_lat and h_lng:
                return float(h_lat), float(h_lng)
    except: pass
    return None, None

def process_group(group, result_list, home_lat, home_lng):
    start_time = group[0]['time']
    end_time = group[-1]['time']
    duration_min = (end_time - start_time).total_seconds() / 60

    if duration_min >= STAY_TIME_MIN or (len(group) > 5 and duration_min > 5):
        center = group[0]
        addr, place = get_place_name(center['lat'], center['lng'])

        if home_lat and home_lng:
            dist = calculate_distance(center['lat'], center['lng'], home_lat, home_lng)
            if dist <= HOME_THRESHOLD:
                place = "집"

        result_list.append({
            "media_type": "location",
            "timestamp": f"{center['time'].strftime('%Y-%m-%d')}T{center['time_str']}",
            "duration_min": int(duration_min),
            "address": addr,
            "place_name": place
        })

def merge_consecutive_logs(places_list):
    if not places_list: return []
    merged = []
    current = places_list[0]
    curr_time = datetime.fromisoformat(current['timestamp'])
    current['_end_time'] = curr_time + timedelta(minutes=current['duration_min'])

    for i in range(1, len(places_list)):
        next_log = places_list[i]
        next_start = datetime.fromisoformat(next_log['timestamp'])
        next_end = next_start + timedelta(minutes=next_log['duration_min'])

        is_same = (current['place_name'] == next_log['place_name'])
        time_gap = (next_start - current['_end_time']).total_seconds() / 60

        if is_same and time_gap <= 60:
            current['_end_time'] = next_end
            total_dur = (current['_end_time'] - curr_time).total_seconds() / 60
            current['duration_min'] = int(total_dur)
        else:
            if '_end_time' in current: del current['_end_time']
            merged.append(current)
            current = next_log
            curr_time = datetime.fromisoformat(current['timestamp'])
            current['_end_time'] = curr_time + timedelta(minutes=current['duration_min'])

    if '_end_time' in current: del current['_end_time']
    merged.append(current)
    return merged
