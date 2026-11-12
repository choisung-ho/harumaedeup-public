const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

// Firebase 관리자 초기화
admin.initializeApp();

// 배포 지역 설정 (기본값 사용 시 생략 가능하지만 명시하면 좋습니다)
setGlobalOptions({ region: "us-central1" });

/**
 * 🚨 환자 이탈 감지 시 보호자에게 푸시 알림 전송 (v2 방식)
 * ✅ [수정됨] 최신 FCM API (send) 사용으로 백그라운드 알림 지원 강화
 */
exports.sendEmergencyNotification = onDocumentUpdated("users/{userId}", async (event) => {
    // 변경 전/후 데이터 가져오기
    const oldData = event.data.before.data();
    const newData = event.data.after.data();

    // 데이터가 없는 경우 방어 코드
    if (!oldData || !newData) return null;

    // 1. 상태가 'emergency'로 변할 때만 실행
    if (oldData.status !== "emergency" && newData.status === "emergency") {

        const patientName = newData.name || "대상자";
        const alertMessage = newData.alertMessage || "안전 구역을 벗어났습니다!";
        const guardianToken = newData.guardianFcmToken;
        const patientId = event.params.userId;

        console.log(`[디버그] 환자: ${patientName}, 토큰: ${guardianToken ? '있음' : '없음'}`);

        if (!guardianToken) {
            console.log(`[중단] ${patientName}님의 보호자 토큰이 없습니다.`);
            return null;
        }

        // 2. ✅ [수정됨] 최신 FCM API용 메시지 구성
        const message = {
            token: guardianToken,
            // notification 필드: 백그라운드/종료 상태에서 시스템이 자동으로 표시
            notification: {
                title: `🚨 비상: ${patientName}님 이탈`,
                body: alertMessage,
            },
            // data 필드: 앱에서 처리할 추가 데이터
            data: {
                type: "emergency",
                patientId: patientId,
                patientName: patientName,
                alertMessage: alertMessage,
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                timestamp: new Date().toISOString(),
            },
            // ✅ [추가] Android 전용 설정: 높은 우선순위 + 알림 채널
            android: {
                priority: "high",
                notification: {
                    channelId: "emergency_channel_id",  // 로컬에서 생성한 채널 ID와 일치해야 함
                    priority: "max",
                    visibility: "public",
                    defaultSound: true,
                    defaultVibrateTimings: true,
                    icon: "ic_launcher",
                    color: "#FF0000",
                }
            },
            // ✅ [추가] APNs (iOS) 설정
            apns: {
                payload: {
                    aps: {
                        alert: {
                            title: `🚨 비상: ${patientName}님 이탈`,
                            body: alertMessage,
                        },
                        sound: "default",
                        badge: 1,
                        contentAvailable: true,
                    }
                }
            }
        };

        // 3. ✅ [수정됨] 최신 send() API 사용 (sendToDevice 대신)
        try {
            const response = await admin.messaging().send(message);
            console.log(`[성공] 알림 전송 완료. Message ID: ${response}`);
        } catch (error) {
            console.error("[오류] 알림 전송 실패:", error);

            // 토큰이 유효하지 않은 경우 토큰 정리
            if (error.code === 'messaging/invalid-registration-token' ||
                error.code === 'messaging/registration-token-not-registered') {
                console.log(`[정리] 유효하지 않은 토큰 발견. 시니어 문서에서 guardianFcmToken 제거.`);
                try {
                    await admin.firestore().collection('users').doc(patientId).update({
                        guardianFcmToken: admin.firestore.FieldValue.delete()
                    });
                } catch (cleanupError) {
                    console.error("[정리 오류]", cleanupError);
                }
            }
        }
    }
    return null;
});
