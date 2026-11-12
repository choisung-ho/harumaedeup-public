import requests
import logging
import os
import math
from time import time

logger = logging.getLogger(__name__)

class TmapManager:
    def __init__(self):
        # [필수] Tmap API 키 (https://endpoint-1.example.invalid/)
        self.api_key = os.getenv("TMAP_API_KEY")
        self.base_url_route = "https://apis.openapi.sk.com/tmap/routes/pedestrian?version=1"
        self.base_url_poi = "https://apis.openapi.sk.com/tmap/pois?version=1"
        self.base_url_around = "https://apis.openapi.sk.com/tmap/pois/search/around?version=1"

        # 캐시: {cache_key: (data, timestamp)}
        self._coord_cache = {}
        self._walking_time_cache = {}
        self.CACHE_TTL = 1800  # 30분 (위치 기반이라 더 짧게)

        # 기본 검색 반경 (미터)
        self.DEFAULT_RADIUS = 3000  # 3km
        self.MAX_RADIUS = 20000     # 20km (확장 검색용)

    def _is_cache_valid(self, timestamp):
        """캐시 유효성 확인"""
        return (time() - timestamp) < self.CACHE_TTL

    def _calculate_distance(self, lat1, lng1, lat2, lng2):
        """두 좌표 간 거리 계산 (Haversine 공식, 미터 단위)"""
        R = 6371000  # 지구 반지름 (미터)

        lat1_rad = math.radians(lat1)
        lat2_rad = math.radians(lat2)
        delta_lat = math.radians(lat2 - lat1)
        delta_lng = math.radians(lng2 - lng1)

        a = math.sin(delta_lat/2)**2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(delta_lng/2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

        return R * c

    def get_coordinates(self, keyword, user_lat=None, user_lng=None, max_retries=3):
        """
        [장소 검색] "블루밍" -> 사용자 위치 주변에서 검색

        Args:
            keyword: 검색어 (상호명, 장소명)
            user_lat: 사용자 현재 위도 (선택, 있으면 주변 검색)
            user_lng: 사용자 현재 경도 (선택, 있으면 주변 검색)

        Returns:
            (lat, lng) 튜플 또는 None
        """
        if not keyword:
            return None

        # 캐시 키: 키워드 + 사용자 위치 (위치 기반이므로)
        if user_lat and user_lng:
            cache_key = f"{keyword}_{user_lat:.3f}_{user_lng:.3f}"
        else:
            cache_key = keyword

        # 캐시 확인
        if cache_key in self._coord_cache:
            cached_data, timestamp = self._coord_cache[cache_key]
            if self._is_cache_valid(timestamp):
                logger.debug(f"🎯 [캐시 히트] {keyword}")
                return cached_data

        # ★ 사용자 위치가 있으면 주변 검색 우선
        if user_lat and user_lng:
            result = self._search_around(keyword, user_lat, user_lng, max_retries)
            if result:
                self._coord_cache[cache_key] = (result, time())
                return result
            # 주변에 없으면 전국 검색으로 폴백
            logger.info(f"📍 [주변 검색 실패] 전국 검색으로 전환: {keyword}")

        # 전국 검색 (기존 방식)
        result = self._search_nationwide(keyword, user_lat, user_lng, max_retries)
        if result:
            self._coord_cache[cache_key] = (result, time())
        return result

    def _search_around(self, keyword, user_lat, user_lng, max_retries=3):
        """
        [주변 검색] 사용자 위치 중심 반경 내 검색
        Tmap 주변 검색 API 사용
        """
        headers = {"appKey": self.api_key}

        # 1차: 5km 반경
        # 2차: 10km 반경 (실패 시)
        # 3차: 20km 반경 (실패 시)
        radii = [self.DEFAULT_RADIUS, 10000, self.MAX_RADIUS]

        for radius in radii:
            params = {
                "searchKeyword": keyword,
                "centerLat": user_lat,
                "centerLon": user_lng,
                "radius": radius,  # 반경 (미터)
                "resCoordType": "WGS84GEO",
                "reqCoordType": "WGS84GEO",
                "count": 10,  # 충분히 가져와서 필터링
                "searchType": "all",  # 명칭+카테고리 검색
                "multiPoint": "N"
            }

            for attempt in range(max_retries):
                try:
                    response = requests.get(self.base_url_around, params=params, headers=headers, timeout=5)

                    if response.status_code == 200:
                        data = response.json()
                        pois = data.get("searchPoiInfo", {}).get("pois", {}).get("poi", [])

                        if pois:
                            # 거리순으로 정렬 (가장 가까운 것 선택)
                            best_poi = self._find_best_match(pois, keyword, user_lat, user_lng)

                            if best_poi:
                                lat = float(best_poi["noorLat"])
                                lng = float(best_poi["noorLon"])
                                name = best_poi.get("name", keyword)
                                distance = self._calculate_distance(user_lat, user_lng, lat, lng)

                                logger.info(f"✅ [주변 검색] '{keyword}' → '{name}' ({distance:.0f}m, 반경 {radius}m)")
                                return (lat, lng)

                    # 결과 없으면 더 넓은 반경으로
                    break

                except requests.Timeout:
                    logger.warning(f"⏱️ [타임아웃] 주변 검색 (시도 {attempt+1}/{max_retries})")
                    continue
                except Exception as e:
                    logger.error(f"❌ [주변 검색 Error] {e}")
                    continue

        return None

    def _search_nationwide(self, keyword, user_lat=None, user_lng=None, max_retries=3):
        """
        [전국 검색] 기존 방식, 하지만 결과를 거리순 정렬
        """
        headers = {"appKey": self.api_key}
        params = {
            "searchKeyword": keyword,
            "resCoordType": "WGS84GEO",
            "reqCoordType": "WGS84GEO",
            "count": 20  # 더 많이 가져와서 필터링
        }

        for attempt in range(max_retries):
            try:
                response = requests.get(self.base_url_poi, params=params, headers=headers, timeout=5)

                if response.status_code == 200:
                    data = response.json()
                    pois = data.get("searchPoiInfo", {}).get("pois", {}).get("poi", [])

                    if pois:
                        # 사용자 위치가 있으면 가장 가까운 곳 선택
                        if user_lat and user_lng:
                            best_poi = self._find_best_match(pois, keyword, user_lat, user_lng)
                        else:
                            best_poi = pois[0]  # 위치 없으면 첫 번째 (정확도순)

                        if best_poi:
                            lat = float(best_poi["noorLat"])
                            lng = float(best_poi["noorLon"])
                            name = best_poi.get("name", keyword)

                            if user_lat and user_lng:
                                distance = self._calculate_distance(user_lat, user_lng, lat, lng)
                                logger.info(f"✅ [전국 검색] '{keyword}' → '{name}' ({distance/1000:.1f}km)")
                            else:
                                logger.info(f"✅ [전국 검색] '{keyword}' → '{name}'")

                            return (lat, lng)
                    else:
                        logger.warning(f"⚠️ [검색 결과 없음] {keyword}")
                        return None
                else:
                    logger.warning(f"⚠️ [장소 검색 실패] {keyword} (Code: {response.status_code})")

            except requests.Timeout:
                logger.warning(f"⏱️ [타임아웃] {keyword} (시도 {attempt+1}/{max_retries})")
                continue
            except Exception as e:
                logger.error(f"❌ [Geocoding Error] {keyword}: {e}")
                continue

        return None

    def _find_best_match(self, pois, keyword, user_lat, user_lng):
        """
        [최적 결과 선택] 거리 + 이름 유사도 기반

        1. 이름이 정확히 일치하면 우선
        2. 그 중 가장 가까운 것 선택
        3. 이름 일치 없으면 가장 가까운 것
        """
        if not pois:
            return None

        keyword_lower = keyword.lower().strip()

        # 거리 계산 및 정렬
        scored_pois = []
        for poi in pois:
            lat = float(poi["noorLat"])
            lng = float(poi["noorLon"])
            name = poi.get("name", "").lower().strip()

            distance = self._calculate_distance(user_lat, user_lng, lat, lng)

            # 점수: 이름 일치 여부 (일치하면 0, 아니면 1) + 거리 (km)
            name_match = 0 if keyword_lower in name or name in keyword_lower else 1
            score = name_match * 100000 + distance  # 이름 일치가 훨씬 중요

            scored_pois.append((poi, score, distance))

        # 점수 낮은 순 (이름 일치 + 가까운 순)
        scored_pois.sort(key=lambda x: x[1])

        best = scored_pois[0]
        logger.debug(f"   🎯 [Best Match] {best[0].get('name')} (거리: {best[2]:.0f}m)")

        return best[0]

    def get_walking_time(self, start_lat, start_lng, end_lat, end_lng, max_retries=3):
        """
        [도보 시간 계산] 출발지 -> 목적지 소요 시간(분) 반환
        """
        # 입력값 검증
        if not all([start_lat, start_lng, end_lat, end_lng]):
            logger.warning("⚠️ [경로 계산] 좌표 누락")
            return None

        # 같은 위치인지 체크 (100m 이내면 0분)
        distance = self._calculate_distance(start_lat, start_lng, end_lat, end_lng)
        if distance < 100:
            logger.info(f"✅ [경로 계산] 목적지 근처 (거리: {distance:.0f}m) → 0분")
            return 0

        # 캐시 키 생성
        cache_key = f"{start_lat:.4f},{start_lng:.4f}→{end_lat:.4f},{end_lng:.4f}"

        # 캐시 확인
        if cache_key in self._walking_time_cache:
            cached_time, timestamp = self._walking_time_cache[cache_key]
            if self._is_cache_valid(timestamp):
                logger.debug(f"🎯 [캐시 히트] 도보 {cached_time}분")
                return cached_time

        headers = {
            "appKey": self.api_key,
            "Content-Type": "application/json"
        }

        payload = {
            "startX": float(start_lng),
            "startY": float(start_lat),
            "endX": float(end_lng),
            "endY": float(end_lat),
            "reqCoordType": "WGS84GEO",
            "resCoordType": "WGS84GEO",
            "startName": "출발지",
            "endName": "목적지"
        }

        for attempt in range(max_retries):
            try:
                response = requests.post(self.base_url_route, json=payload, headers=headers, timeout=10)

                if response.status_code == 200:
                    data = response.json()

                    if 'features' in data and len(data['features']) > 0:
                        total_time_sec = data['features'][0]['properties']['totalTime']
                        total_distance = data['features'][0]['properties']['totalDistance']
                        walking_min = max(1, int(total_time_sec / 60))  # 최소 1분

                        # 캐시 저장
                        self._walking_time_cache[cache_key] = (walking_min, time())
                        logger.info(f"✅ [경로 계산] 도보 {walking_min}분 ({total_distance}m)")
                        return walking_min
                    else:
                        # API 성공했지만 경로 없음 → 직선거리로 추정
                        estimated_min = max(1, int(distance / 67))  # 분당 67m (시속 4km)
                        logger.warning(f"⚠️ [경로 없음] 직선거리 기반 추정: {estimated_min}분")
                        return estimated_min
                else:
                    logger.warning(f"⚠️ [경로 계산 실패] Code: {response.status_code}")

            except requests.Timeout:
                logger.warning(f"⏱️ [타임아웃] 경로 계산 (시도 {attempt+1}/{max_retries})")
                continue
            except Exception as e:
                logger.error(f"❌ [경로 계산 Error] {e}")
                continue

        # 모든 시도 실패 → 직선거리로 추정
        estimated_min = max(1, int(distance / 67))
        logger.warning(f"⚠️ [API 실패] 직선거리 기반 추정: {estimated_min}분")
        return estimated_min

    def clear_cache(self):
        """캐시 초기화"""
        self._coord_cache.clear()
        self._walking_time_cache.clear()
        logger.info("🗑️ [캐시 초기화] 완료")

    def get_cache_stats(self):
        """캐시 통계"""
        return {
            "coord_cache_size": len(self._coord_cache),
            "walking_time_cache_size": len(self._walking_time_cache)
        }

# 전역 인스턴스
routing_mgr = TmapManager()
