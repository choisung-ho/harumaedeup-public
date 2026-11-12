import os
import json
import base64
from cryptography.fernet import Fernet


class CryptoManager:
    _cipher = None

    @classmethod
    def _get_cipher(cls):
        """실제로 암호화/복호화가 필요할 때만 키를 로드하고 객체를 생성합니다 (Lazy Loading)"""
        if cls._cipher is None:
            # .env 파일 로드 없이 바로 환경변수에서 가져옵니다.
            # (로컬에서는 IDE 설정이나 터미널 환경변수로, 배포 시엔 set-env-vars로 주입됨)
            key = os.getenv("ENCRYPTION_KEY")

            # [안전장치] 키가 없으면 에러 대신 None 반환 (배포 중 분석 단계 통과용)
            if not key:
                return None

            try:
                cls._cipher = Fernet(key.encode())
            except Exception as e:
                print(f"⚠️ 암호화 키 오류: {e}")
                return None
        return cls._cipher
    @staticmethod
    def encrypt_data(data) -> str:
        """
        무엇이든(문자열, 리스트, 딕셔너리) 받아서 암호화된 문자열로 반환
        """
        cipher = CryptoManager._get_cipher()
        if cipher is None: return None

        if data is None:
            return None

        # 1. 데이터를 문자열(JSON)로 변환
        if not isinstance(data, str):
            text_data = json.dumps(data, ensure_ascii=False)
        else:
            text_data = data

        # 2. 바이트로 변환 후 암호화
        encrypted_bytes = cipher.encrypt(text_data.encode('utf-8'))

        # 3. DB 저장을 위해 문자열로 변환 (Base64)
        return encrypted_bytes.decode('utf-8')

    @staticmethod
    def decrypt_data(encrypted_str: str):
        """
        암호화된 문자열을 받아서 원래 데이터로 복원
        """
        cipher = CryptoManager._get_cipher()
        if cipher is None: return None

        if encrypted_str is None:
            return None

        try:
            # 1. 복호화
            decrypted_bytes = cipher.decrypt(encrypted_str.encode('utf-8'))
            decrypted_str = decrypted_bytes.decode('utf-8')

            # 2. JSON 파싱 시도 (리스트나 딕셔너리였을 경우 복원)
            try:
                return json.loads(decrypted_str)
            except json.JSONDecodeError:
                return decrypted_str # 그냥 문자열이었으면 그대로 반환

        except Exception as e:
            print(f"⚠️ 복호화 실패: {e}")
            return None
