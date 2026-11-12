// lib/services/auto_upload_service.dart
// 시니어 모드 전용 자동 업로드 서비스
// 통화 녹음, 사진, 동영상, SMS 로그를 Firebase Storage로 자동 업로드

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart'; // ✅ [추가] timestamp 포맷팅용

/// 자동 업로드 서비스 (시니어 모드 전용)
/// Guardian 모드에서는 절대 실행되지 않음
class AutoUploadService {
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ✅ [추가] SAF 채널
  static const MethodChannel _safChannel = MethodChannel(
    'com.example.my_first_app/saf',
  );

  // 싱글톤 패턴
  static final AutoUploadService _instance = AutoUploadService._internal();
  factory AutoUploadService() => _instance;
  AutoUploadService._internal();

  // 상태 관리
  bool _isInitialized = false;
  bool _isRunning = false;
  Timer? _periodicTimer;

  // ✅ [핵심 추가] 로컬 중복 방지 캐시 (SharedPreferences에 영구 저장)
  final Set<String> _uploadedHashes = {};

  // ✅ [핵심 추가] SharedPreferences 키
  static const String _uploadedHashesKey = 'auto_upload_uploaded_hashes';

  // ✅ [핵심] 서비스 시작 시간 - 이 시간 이후 생성된 파일만 업로드
  DateTime? _serviceStartTime;

  // 파일 감시를 위한 마지막 체크 시간
  DateTime? _lastCallCheckTime;
  DateTime? _lastPhotoCheckTime;
  DateTime? _lastVideoCheckTime;

  /// 서비스 초기화 (앱 시작 시 호출)
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 역할 확인 - 시니어 모드(role=2)만 활성화
      final canRun = await _canRunAutoUpload();
      if (!canRun) {
        debugPrint("🚫 [AutoUpload] Guardian 모드 - 자동 업로드 비활성화");
        return;
      }

      _isInitialized = true;
      debugPrint("✅ [AutoUpload] 서비스 초기화 완료");

      // ✅ [핵심] 서비스 시작 시간 설정 - 이 시간 이후 파일만 업로드
      await _initServiceStartTime();

      // ✅ [핵심 추가] 업로드 캐시 로드 (SharedPreferences에서)
      await _loadUploadedHashesCache();

      // 저장된 마지막 체크 시간 로드
      await _loadLastCheckTimes();

      // 초기 스캔 실행
      await scanAndUploadAll();

      // 주기적 스캔 시작 (15분마다)
      _startPeriodicScan();
    } catch (e) {
      debugPrint("❌ [AutoUpload] 초기화 오류: $e");
    }
  }

  /// 역할 확인 - 시니어 모드(role=2)만 true 반환
  Future<bool> _canRunAutoUpload() async {
    try {
      // ✅ [핵심 수정] FirebaseAuth에서 직접 UID 가져오기 (SharedPreferences 의존 제거)
      final currentUid = FirebaseAuth.instance.currentUser?.uid;

      if (currentUid == null) {
        debugPrint("⚠️ [AutoUpload] Firebase 로그인 안됨");
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString('user_role_$currentUid');
      debugPrint("🔍 [AutoUpload] UID=$currentUid, role=$role");
      // role == '2' -> 시니어 모드
      // role == '1' -> Guardian 모드 (절대 실행 안 함)
      return role == '2';
    } catch (e) {
      debugPrint("❌ [AutoUpload] 역할 확인 오류: $e");
      return false;
    }
  }

  /// ✅ [핵심] 서비스 시작 시간 초기화
  /// 처음 시니어 모드 진입 시 현재 시간을 저장하고,
  /// 이후에는 저장된 시간을 사용 (이 시간 이후 파일만 업로드)
  Future<void> _initServiceStartTime() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTime = prefs.getInt('auto_upload_service_start_time');

    if (savedTime != null) {
      _serviceStartTime = DateTime.fromMillisecondsSinceEpoch(savedTime);
      debugPrint("📅 [AutoUpload] 기존 서비스 시작 시간: $_serviceStartTime");
    } else {
      // 최초 시니어 모드 진입 - 현재 시간 저장
      _serviceStartTime = DateTime.now();
      await prefs.setInt(
        'auto_upload_service_start_time',
        _serviceStartTime!.millisecondsSinceEpoch,
      );
      debugPrint("📅 [AutoUpload] 새 서비스 시작 시간 설정: $_serviceStartTime");
    }
  }

  /// ✅ [핵심 추가] 업로드된 파일 해시 캐시 로드 (SharedPreferences에서)
  Future<void> _loadUploadedHashesCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // ✅ [핵심] 디스크에서 최신 데이터 강제 로드 (다른 프로세스가 저장한 데이터 반영)
      await prefs.reload();

      final savedHashes = prefs.getStringList(_uploadedHashesKey) ?? [];

      // 기존 메모리 캐시에 병합 (Set이므로 중복 자동 제거)
      final beforeCount = _uploadedHashes.length;
      _uploadedHashes.addAll(savedHashes);
      final afterCount = _uploadedHashes.length;

      debugPrint(
        "📂 [AutoUpload] 캐시 로드: 디스크=${savedHashes.length}개, 메모리=$beforeCount→$afterCount개",
      );
    } catch (e) {
      debugPrint("⚠️ [AutoUpload] 캐시 로드 오류: $e");
    }
  }

  /// ✅ [핵심 추가] 업로드된 파일 해시를 캐시에 저장 (SharedPreferences에 영구 저장)
  Future<void> _saveUploadedHashToCache(String hashKey) async {
    try {
      // 메모리 캐시에 먼저 추가 (즉시 중복 방지)
      _uploadedHashes.add(hashKey);

      // SharedPreferences에 영구 저장
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_uploadedHashesKey, _uploadedHashes.toList());
      debugPrint(
        "💾 [AutoUpload] 캐시 저장: $hashKey (총 ${_uploadedHashes.length}개)",
      );
    } catch (e) {
      debugPrint("⚠️ [AutoUpload] 캐시 저장 오류: $e");
    }
  }

  /// 현재 로그인 사용자 UID 가져오기
  String? get _currentUid => FirebaseAuth.instance.currentUser?.uid;

  /// 마지막 체크 시간 로드
  Future<void> _loadLastCheckTimes() async {
    final prefs = await SharedPreferences.getInstance();
    final callTime = prefs.getInt('auto_upload_last_call_check');
    final photoTime = prefs.getInt('auto_upload_last_photo_check');
    final videoTime = prefs.getInt('auto_upload_last_video_check');

    if (callTime != null) {
      _lastCallCheckTime = DateTime.fromMillisecondsSinceEpoch(callTime);
    }
    if (photoTime != null) {
      _lastPhotoCheckTime = DateTime.fromMillisecondsSinceEpoch(photoTime);
    }
    if (videoTime != null) {
      _lastVideoCheckTime = DateTime.fromMillisecondsSinceEpoch(videoTime);
    }
  }

  /// 마지막 체크 시간 저장
  Future<void> _saveLastCheckTimes() async {
    final prefs = await SharedPreferences.getInstance();
    if (_lastCallCheckTime != null) {
      await prefs.setInt(
        'auto_upload_last_call_check',
        _lastCallCheckTime!.millisecondsSinceEpoch,
      );
    }
    if (_lastPhotoCheckTime != null) {
      await prefs.setInt(
        'auto_upload_last_photo_check',
        _lastPhotoCheckTime!.millisecondsSinceEpoch,
      );
    }
    if (_lastVideoCheckTime != null) {
      await prefs.setInt(
        'auto_upload_last_video_check',
        _lastVideoCheckTime!.millisecondsSinceEpoch,
      );
    }
  }

  /// 주기적 스캔 시작
  void _startPeriodicScan() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(minutes: 15), (timer) async {
      if (await _canRunAutoUpload()) {
        await scanAndUploadAll();
      }
    });
  }

  /// 서비스 중지
  void dispose() {
    _periodicTimer?.cancel();
    _isRunning = false;
    _isInitialized = false;
    debugPrint("🛑 [AutoUpload] 서비스 중지");
  }

  // ✅ [핵심 추가] 동시 실행 방지를 위한 Completer
  Completer<void>? _scanCompleter;

  /// 모든 미디어 스캔 및 업로드
  Future<void> scanAndUploadAll() async {
    // ✅ [핵심] 이미 실행 중이면 기존 작업 완료 대기
    if (_isRunning && _scanCompleter != null) {
      debugPrint("⏳ [AutoUpload] 이미 실행 중 - 완료 대기...");
      await _scanCompleter!.future;
      return;
    }

    if (_isRunning) {
      debugPrint("⏳ [AutoUpload] 이미 실행 중...");
      return;
    }

    if (!await _canRunAutoUpload()) {
      debugPrint("🚫 [AutoUpload] Guardian 모드 - 스킵");
      return;
    }

    _isRunning = true;
    _scanCompleter = Completer<void>();

    // ✅✅✅ [핵심 수정] 매번 스캔 시작 전 SharedPreferences에서 캐시 로드 ✅✅✅
    // 포그라운드/백그라운드 어디서 호출해도 항상 최신 캐시를 로드
    await _loadUploadedHashesCache();

    debugPrint("🔄 [AutoUpload] 전체 스캔 시작... (캐시: ${_uploadedHashes.length}개)");

    try {
      await Future.wait([
        _scanAndUploadCallRecordings(),
        _scanAndUploadPhotos(),
        _scanAndUploadVideos(),
      ]);

      await _saveLastCheckTimes();
      debugPrint("✅ [AutoUpload] 전체 스캔 완료");
    } catch (e) {
      debugPrint("❌ [AutoUpload] 스캔 오류: $e");
    } finally {
      _isRunning = false;
      _scanCompleter?.complete();
      _scanCompleter = null;
    }
  }

  /// 통화 녹음 스캔 및 업로드 (SAF 폴더 - Android DocumentFile API 사용)
  Future<void> _scanAndUploadCallRecordings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // ✅ [핵심 추가] 디스크에서 최신 데이터 강제 로드
      await prefs.reload();

      // SAF URI 또는 일반 경로 가져오기
      final folderUri = prefs.getString('recording_folder_uri');
      final folderPath = prefs.getString('recording_folder_path');

      debugPrint("🔍 [Calls] 설정 확인 - URI: $folderUri, Path: $folderPath");

      // ✅ [수정] 잘못된 URI 형식 자동 정리 (content://가 아닌 경우)
      if (folderUri != null && !folderUri.startsWith('content://')) {
        debugPrint("⚠️ [Calls] 잘못된 URI 형식 감지, 정리: $folderUri");
        await prefs.remove('recording_folder_uri');
        // path로 폴백 시도
        if (folderPath == null) {
          await prefs.setString('recording_folder_path', folderUri);
        }
        await prefs.reload();
      }

      // 재확인
      final validUri = prefs.getString('recording_folder_uri');
      final validPath = prefs.getString('recording_folder_path');

      if (validUri == null && validPath == null) {
        debugPrint("📁 [Calls] SAF 폴더 미설정 - 권한 설정 페이지에서 폴더를 선택해주세요");
        return;
      }

      int uploadedCount = 0;

      // ✅ SAF URI인 경우 (content://...)
      if (validUri != null && validUri.startsWith('content://')) {
        debugPrint("📁 [Calls] SAF URI로 접근: $validUri");
        uploadedCount = await _scanCallRecordingsViaSaf(validUri);
      }
      // 일반 파일 경로인 경우
      else if (validPath != null) {
        debugPrint("📁 [Calls] 일반 경로로 접근: $validPath");
        uploadedCount = await _scanCallRecordingsViaPath(validPath);
      }

      _lastCallCheckTime = DateTime.now();
      debugPrint("📞 [Calls] 업로드 완료: $uploadedCount개");
    } catch (e) {
      debugPrint("❌ [Calls] 스캔 오류: $e");
    }
  }

  /// ✅ SAF API를 통한 통화 녹음 스캔 (Android DocumentFile)
  Future<int> _scanCallRecordingsViaSaf(String treeUri) async {
    int uploadedCount = 0;

    try {
      // ✅ [핵심 추가] SAF 폴더 권한 받은 시간 가져오기
      final prefs = await SharedPreferences.getInstance();
      final safPermissionTime = prefs.getInt('saf_folder_permission_time');
      final DateTime? safPermissionDateTime = safPermissionTime != null
          ? DateTime.fromMillisecondsSinceEpoch(safPermissionTime)
          : null;

      debugPrint("📅 [Calls] SAF 권한 시간: $safPermissionDateTime");

      // Android Native에서 SAF 폴더 내 파일 목록 가져오기
      final List<dynamic> files = await _safChannel.invokeMethod('listFiles', {
        'uri': treeUri,
      });

      debugPrint("📁 [Calls] SAF에서 ${files.length}개 파일 발견");

      // ✅ [성능 개선] 스캔 단계에서 시간+중복 필터링 (불필요한 네이티브 호출 제거)
      final DateTime filterTime =
          safPermissionDateTime ?? _serviceStartTime ?? DateTime.now();
      final List<Map<String, dynamic>> filesToUpload = [];

      for (var fileInfo in files) {
        final Map<String, dynamic> file = Map<String, dynamic>.from(fileInfo);
        final String fileName = file['name'] as String;
        final int lastModified = file['lastModified'] as int;
        final int fileSize = file['size'] as int;

        final fileModifiedTime = DateTime.fromMillisecondsSinceEpoch(
          lastModified,
        );

        final isAfterPermission = fileModifiedTime.isAfter(filterTime);
        final isAfterLastCheck =
            _lastCallCheckTime == null ||
            fileModifiedTime.isAfter(_lastCallCheckTime!);

        // ✅ [성능 개선] 캐시 중복 체크를 스캔 단계에서 수행
        final cacheKey = 'calls_${fileName}_$fileSize';
        final isAlreadyUploaded = _uploadedHashes.contains(cacheKey);

        if (isAfterPermission && isAfterLastCheck && !isAlreadyUploaded) {
          debugPrint(
            "📞 [Calls] 새 녹음 파일 발견: $fileName (수정시간: $fileModifiedTime, 기준시간: $filterTime)",
          );
          filesToUpload.add(file);
        } else {
          debugPrint(
            "⏭️ [Calls] 스킵: $fileName (시간필터: ${!isAfterPermission || !isAfterLastCheck}, 중복: $isAlreadyUploaded)",
          );
        }
      }

      debugPrint(
        "📁 [Calls] 업로드 대상: ${filesToUpload.length}개 / 전체: ${files.length}개",
      );

      // ✅ [성능 개선] 병렬 업로드 (최대 3개 동시)
      for (int i = 0; i < filesToUpload.length; i += 3) {
        final batch = filesToUpload.skip(i).take(3).toList();
        final results = await Future.wait(
          batch.map(
            (file) => _uploadFileViaSaf(
              fileUri: file['uri'] as String,
              fileName: file['name'] as String,
              fileSize: file['size'] as int,
              storagePath: 'calls',
              contentType: file['mimeType'] as String? ?? 'audio/mpeg',
            ),
          ),
        );
        uploadedCount += results.where((r) => r).length;
      }
    } catch (e) {
      debugPrint("❌ [Calls] SAF 스캔 오류: $e");

      // ✅ [핵심 수정] SAF 실패 시 일반 경로로 폴백 시도
      final prefs = await SharedPreferences.getInstance();

      // 1순위: 저장된 일반 경로
      String? fallbackPath = prefs.getString('recording_folder_path');

      // 2순위: SAF URI에서 경로 추출 시도
      if (fallbackPath == null || fallbackPath.startsWith('content://')) {
        fallbackPath = _extractPathFromSafUri(treeUri);
      }

      // 3순위: 기본 통화 녹음 경로들 시도
      if (fallbackPath == null) {
        final defaultPaths = [
          '/storage/emulated/0/Recordings/Call',
          '/storage/emulated/0/Call',
          '/storage/emulated/0/DCIM/Call',
          '/storage/emulated/0/Music/Recordings',
          '/storage/emulated/0/Recordings',
        ];

        for (var path in defaultPaths) {
          if (await Directory(path).exists()) {
            fallbackPath = path;
            debugPrint("🔄 [Calls] 기본 경로 발견: $fallbackPath");
            break;
          }
        }
      }

      if (fallbackPath != null && !fallbackPath.startsWith('content://')) {
        debugPrint("🔄 [Calls] 일반 경로로 폴백: $fallbackPath");
        return await _scanCallRecordingsViaPath(fallbackPath);
      } else {
        debugPrint("⚠️ [Calls] 폴백 경로 없음 - 통화 녹음 스캔 불가");
      }
    }

    return uploadedCount;
  }

  /// ✅ [추가] SAF URI에서 실제 파일 경로 추출
  String? _extractPathFromSafUri(String safUri) {
    try {
      // content://com.android.externalstorage.documents/tree/primary%3ARecordings%2FCall
      // -> /storage/emulated/0/Recordings/Call

      final uri = Uri.parse(safUri);
      final encodedPath = uri.pathSegments.lastOrNull;

      if (encodedPath != null) {
        // URL 디코딩: %3A -> :, %2F -> /
        final decodedPath = Uri.decodeComponent(encodedPath);

        // "primary:Recordings/Call" -> "/storage/emulated/0/Recordings/Call"
        if (decodedPath.startsWith('primary:')) {
          final relativePath = decodedPath.substring(8); // 'primary:' 제거
          final fullPath = '/storage/emulated/0/$relativePath';
          debugPrint("📁 [Calls] SAF URI에서 경로 추출: $fullPath");
          return fullPath;
        }
      }
    } catch (e) {
      debugPrint("⚠️ [Calls] SAF URI 경로 추출 실패: $e");
    }
    return null;
  }

  /// 일반 파일 경로를 통한 통화 녹음 스캔
  Future<int> _scanCallRecordingsViaPath(String folderPath) async {
    int uploadedCount = 0;

    try {
      // ✅ [핵심 추가] 폴더 권한 받은 시간 가져오기
      final prefs = await SharedPreferences.getInstance();
      final safPermissionTime = prefs.getInt('saf_folder_permission_time');
      final DateTime? safPermissionDateTime = safPermissionTime != null
          ? DateTime.fromMillisecondsSinceEpoch(safPermissionTime)
          : null;

      final directory = Directory(folderPath);
      if (!await directory.exists()) {
        debugPrint("📁 [Calls] 폴더가 존재하지 않음: $folderPath");
        return 0;
      }

      final files = await directory.list().toList();
      final audioExtensions = [
        '.mp3',
        '.m4a',
        '.wav',
        '.3gp',
        '.amr',
        '.aac',
        '.ogg',
      ];

      // ✅ [성능 개선] 스캔 단계에서 시간+중복 필터링
      final DateTime filterTime =
          safPermissionDateTime ?? _serviceStartTime ?? DateTime.now();
      final List<MapEntry<File, String>> filesToUpload = [];

      for (var entity in files) {
        if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (audioExtensions.contains(ext)) {
            final stat = await entity.stat();

            final isAfterPermission = stat.modified.isAfter(filterTime);
            final isAfterLastCheck =
                _lastCallCheckTime == null ||
                stat.modified.isAfter(_lastCallCheckTime!);

            // ✅ [성능 개선] 캐시 중복 체크를 스캔 단계에서 수행
            final fileName = path.basename(entity.path);
            final cacheKey = 'calls_${fileName}_${stat.size}';
            final isAlreadyUploaded = _uploadedHashes.contains(cacheKey);

            if (isAfterPermission && isAfterLastCheck && !isAlreadyUploaded) {
              filesToUpload.add(MapEntry(entity, ext));
            }
          }
        }
      }

      debugPrint(
        "📁 [Calls] 업로드 대상: ${filesToUpload.length}개 / 전체: ${files.length}개",
      );

      // ✅ [성능 개선] 병렬 업로드 (최대 3개 동시)
      for (int i = 0; i < filesToUpload.length; i += 3) {
        final batch = filesToUpload.skip(i).take(3).toList();
        final results = await Future.wait(
          batch.map(
            (entry) => _uploadFile(
              file: entry.key,
              storagePath: 'calls',
              contentType: 'audio/${entry.value.substring(1)}',
            ),
          ),
        );
        uploadedCount += results.where((r) => r).length;
      }
    } catch (e) {
      debugPrint("❌ [Calls] 경로 스캔 오류: $e");
    }

    return uploadedCount;
  }

  /// ✅ SAF URI에서 파일 읽어서 업로드
  Future<bool> _uploadFileViaSaf({
    required String fileUri,
    required String fileName,
    required int fileSize,
    required String storagePath,
    required String contentType,
  }) async {
    final uid = _currentUid;
    if (uid == null) return false;

    try {
      // ✅✅✅ [핵심 수정] 파일명+크기 기반 캐시 키 (SAF/일반경로 통일) ✅✅✅
      // 같은 파일이 SAF와 일반 경로에서 다른 해시를 갖는 문제 해결
      final cacheKey = '${storagePath}_${fileName}_$fileSize';

      // Storage 메타데이터용 해시 (별도 생성)
      final fileHash = md5
          .convert(utf8.encode('${fileUri}_${fileSize}_$fileName'))
          .toString();

      // ✅✅✅ [핵심] 캐시에서 중복 체크 ✅✅✅
      if (_uploadedHashes.contains(cacheKey)) {
        debugPrint(
          "⏭️ [Upload] 중복 스킵 (이미 업로드됨): $fileName [캐시: ${_uploadedHashes.length}개]",
        );
        return false;
      }

      // ✅ 업로드 시작 전 캐시에 즉시 추가 (다른 프로세스 중복 방지)
      await _saveUploadedHashToCache(cacheKey);
      debugPrint(
        "📤 [Upload] SAF 업로드 시작: $fileName [캐시에 등록됨: ${_uploadedHashes.length}개]",
      );

      // ✅ SAF API를 통해 파일 바이트 읽기
      final Uint8List fileBytes = await _safChannel.invokeMethod('readFile', {
        'uri': fileUri,
      });

      debugPrint(
        "📤 [Upload] SAF 파일 읽기 완료: $fileName (${fileBytes.length} bytes)",
      );

      // Storage 경로 설정 (✅ 원본 파일명 그대로 사용)
      final uploadPath = 'Users/$uid/source/$storagePath/$fileName';

      final ref = _storage.ref(uploadPath);
      final metadata = SettableMetadata(
        contentType: contentType,
        customMetadata: {
          'original_name': fileName,
          'upload_time': DateTime.now().toIso8601String(),
          'file_hash': fileHash,
          'source': 'saf_upload',
        },
      );

      // 업로드 실행
      await ref.putData(fileBytes, metadata);

      debugPrint("✅ [Upload] SAF 파일 업로드 성공: $fileName -> $uploadPath");
      return true;
    } catch (e) {
      debugPrint("❌ [Upload] SAF 파일 업로드 실패: $fileName - $e");
      return false;
    }
  }

  /// 사진 스캔 및 업로드 (DCIM/Camera)
  Future<void> _scanAndUploadPhotos() async {
    try {
      // ✅ [핵심 추가] 저장소 권한 받은 시간 가져오기
      final prefs = await SharedPreferences.getInstance();
      final storagePermissionTime = prefs.getInt('storage_permission_time');
      final DateTime? storagePermissionDateTime = storagePermissionTime != null
          ? DateTime.fromMillisecondsSinceEpoch(storagePermissionTime)
          : null;

      debugPrint("📅 [Photos] 저장소 권한 시간: $storagePermissionDateTime");

      final photoDirs = [
        '/storage/emulated/0/DCIM/Camera',
        '/storage/emulated/0/Pictures',
        '/storage/emulated/0/DCIM',
      ];

      final imageExtensions = ['.jpg', '.jpeg', '.png', '.heic', '.webp'];
      int uploadedCount = 0;

      for (var dirPath in photoDirs) {
        final directory = Directory(dirPath);
        if (!await directory.exists()) continue;

        try {
          await for (var entity in directory.list(recursive: false)) {
            if (entity is File) {
              final ext = path.extension(entity.path).toLowerCase();
              if (imageExtensions.contains(ext)) {
                final stat = await entity.stat();

                // ✅ [핵심 수정] 저장소 권한 받은 시간 이후 파일만 업로드
                final DateTime filterTime =
                    storagePermissionDateTime ??
                    _serviceStartTime ??
                    DateTime.now();
                final isAfterPermission = stat.modified.isAfter(filterTime);
                final isAfterLastCheck =
                    _lastPhotoCheckTime == null ||
                    stat.modified.isAfter(_lastPhotoCheckTime!);

                if (isAfterPermission && isAfterLastCheck) {
                  final success = await _uploadFile(
                    file: entity,
                    storagePath: 'images',
                    contentType: 'image/${ext.substring(1)}',
                  );

                  if (success) uploadedCount++;
                }
              }
            }
          }
        } catch (e) {
          debugPrint("📸 [Photos] $dirPath 접근 오류: $e");
        }
      }

      _lastPhotoCheckTime = DateTime.now();
      debugPrint("📸 [Photos] 업로드 완료: $uploadedCount개");
    } catch (e) {
      debugPrint("❌ [Photos] 스캔 오류: $e");
    }
  }

  /// 동영상 스캔 및 업로드 (DCIM/Camera)
  Future<void> _scanAndUploadVideos() async {
    try {
      // ✅ [핵심 추가] 저장소 권한 받은 시간 가져오기
      final prefs = await SharedPreferences.getInstance();
      final storagePermissionTime = prefs.getInt('storage_permission_time');
      final DateTime? storagePermissionDateTime = storagePermissionTime != null
          ? DateTime.fromMillisecondsSinceEpoch(storagePermissionTime)
          : null;

      debugPrint("📅 [Videos] 저장소 권한 시간: $storagePermissionDateTime");

      final videoDirs = [
        '/storage/emulated/0/DCIM/Camera',
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/DCIM',
      ];

      final videoExtensions = ['.mp4', '.3gp', '.mkv', '.avi', '.mov', '.webm'];
      int uploadedCount = 0;

      for (var dirPath in videoDirs) {
        final directory = Directory(dirPath);
        if (!await directory.exists()) continue;

        try {
          await for (var entity in directory.list(recursive: false)) {
            if (entity is File) {
              final ext = path.extension(entity.path).toLowerCase();
              if (videoExtensions.contains(ext)) {
                final stat = await entity.stat();

                // ✅ [핵심 수정] 저장소 권한 받은 시간 이후 파일만 업로드
                final DateTime filterTime =
                    storagePermissionDateTime ??
                    _serviceStartTime ??
                    DateTime.now();
                final isAfterPermission = stat.modified.isAfter(filterTime);
                final isAfterLastCheck =
                    _lastVideoCheckTime == null ||
                    stat.modified.isAfter(_lastVideoCheckTime!);

                if (isAfterPermission && isAfterLastCheck) {
                  final success = await _uploadFile(
                    file: entity,
                    storagePath: 'videos',
                    contentType: 'video/${ext.substring(1)}',
                  );

                  if (success) uploadedCount++;
                }
              }
            }
          }
        } catch (e) {
          debugPrint("🎬 [Videos] $dirPath 접근 오류: $e");
        }
      }

      _lastVideoCheckTime = DateTime.now();
      debugPrint("🎬 [Videos] 업로드 완료: $uploadedCount개");
    } catch (e) {
      debugPrint("❌ [Videos] 스캔 오류: $e");
    }
  }

  /// 파일 업로드 (중복 체크 포함)
  Future<bool> _uploadFile({
    required File file,
    required String storagePath,
    required String contentType,
  }) async {
    final uid = _currentUid;
    if (uid == null) return false;

    try {
      // 파일명 및 크기 가져오기
      final fileName = path.basename(file.path);
      final fileStat = await file.stat();
      final fileSize = fileStat.size;

      // ✅✅✅ [핵심 수정] 파일명+크기 기반 캐시 키 (SAF/일반경로 통일) ✅✅✅
      final cacheKey = '${storagePath}_${fileName}_$fileSize';

      // Storage 메타데이터용 해시 (별도 생성)
      final fileHash = await _getFileHash(file);

      // ✅✅✅ [핵심] 캐시에서 중복 체크 ✅✅✅
      if (_uploadedHashes.contains(cacheKey)) {
        debugPrint(
          "⏭️ [Upload] 중복 스킵 (이미 업로드됨): $fileName [캐시: ${_uploadedHashes.length}개]",
        );
        return false;
      }

      // ✅ 업로드 시작 전 캐시에 즉시 추가 (다른 프로세스 중복 방지)
      await _saveUploadedHashToCache(cacheKey);
      debugPrint(
        "📤 [Upload] 업로드 시작: $fileName [캐시에 등록됨: ${_uploadedHashes.length}개]",
      );

      // Storage 경로: Users/{uid}/source/{type}/{filename} (✅ 원본 파일명 그대로 사용)
      final uploadPath = 'Users/$uid/source/$storagePath/$fileName';

      final ref = _storage.ref(uploadPath);
      final metadata = SettableMetadata(
        contentType: contentType,
        customMetadata: {
          'original_name': fileName,
          'upload_time': DateTime.now().toIso8601String(),
          'file_hash': fileHash,
        },
      );

      // 업로드 실행
      await ref.putFile(file, metadata);

      debugPrint("✅ [Upload] 성공: $fileName -> $uploadPath");
      return true;
    } catch (e) {
      debugPrint("❌ [Upload] 실패: ${file.path} - $e");
      return false;
    }
  }

  /// 파일 해시 생성 (MD5) - ✅ 스트림 방식으로 대용량 파일 지원
  Future<String> _getFileHash(File file) async {
    try {
      // ✅ [성능 개선] 스트림 방식으로 파일 해시 계산 (메모리 절약)
      final fileStat = await file.stat();
      if (fileStat.size > 10 * 1024 * 1024) {
        // 10MB 이상: 파일명+크기+수정시간으로 빠르게 해시 생성
        final combined =
            '${path.basename(file.path)}_${fileStat.size}_${fileStat.modified.millisecondsSinceEpoch}';
        return md5.convert(utf8.encode(combined)).toString();
      }
      // 10MB 이하: 전체 파일 해시
      final bytes = await file.readAsBytes();
      return md5.convert(bytes).toString();
    } catch (e) {
      // 폴백: 파일명+크기+수정시간으로 대체
      final stat = await file.stat();
      final combined =
          '${path.basename(file.path)}_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
      return md5.convert(utf8.encode(combined)).toString();
    }
  }

  /// SMS 로그 업로드 (NotificationListenerService에서 호출)
  /// ✅ [수정] 완벽한 JSON 형식으로 변경
  Future<void> uploadSmsLog({
    required String sender,
    required String message,
    required DateTime timestamp,
    String? packageName,
    String? appName,
  }) async {
    if (!await _canRunAutoUpload()) return;

    final uid = _currentUid;
    if (uid == null) return;

    try {
      // ✅ [수정] 요청된 JSON 형식에 맞춤
      final smsData = {
        'media_type': 'sms',
        'sender_phone': sender,
        'message_body': message,
        'app_name': appName ?? _getAppNameFromPackage(packageName),
        'package_name': packageName ?? 'unknown',
        'timestamp': DateFormat(
          'yyyy-MM-dd HH:mm:ss',
        ).format(timestamp), // ✅ 형님이 원하는 형식!
      };

      final jsonContent = jsonEncode(smsData);
      final fileName = 'sms_${timestamp.millisecondsSinceEpoch}.json';
      final storagePath = 'Users/$uid/source/sms_logs/$fileName';

      final ref = _storage.ref(storagePath);
      await ref.putString(
        jsonContent,
        format: PutStringFormat.raw,
        metadata: SettableMetadata(contentType: 'application/json'),
      );

      debugPrint("📱 [SMS] 로그 업로드: $sender");
    } catch (e) {
      debugPrint("❌ [SMS] 업로드 오류: $e");
    }
  }

  /// 패키지명에서 앱 이름 추출
  String _getAppNameFromPackage(String? packageName) {
    if (packageName == null) return '알 수 없음';

    final appNames = {
      'com.samsung.android.messaging': '삼성 메시지',
      'com.google.android.apps.messaging': 'Google 메시지',
      'com.android.mms': '기본 메시지',
      'com.skt.prod.dialer': 'T전화',
      'com.kt.tphone': 'KT 메시지',
      'com.lguplus.usimsafe': 'U+ 메시지',
    };

    return appNames[packageName] ?? packageName.split('.').last;
  }
}
