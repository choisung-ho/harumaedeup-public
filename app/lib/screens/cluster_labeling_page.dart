import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import '../models/cluster_suggestion.dart';
import '../services/clustering_service.dart';
import '../services/connection_service.dart';

/// 얼굴 클러스터링 라벨링 화면
/// 보호자 모드에서 AI가 자동으로 분류한 얼굴 그룹에 이름을 지정할 수 있습니다.
///
/// ⚠️ 중요: 이 화면은 보호자-시니어 연결 검증을 수행합니다.
/// - 보호자가 로그인한 경우: 연결된 시니어의 클러스터 데이터를 조회
/// - 시니어가 로그인한 경우: 본인의 클러스터 데이터를 조회
class ClusterLabelingPage extends StatefulWidget {
  /// 현재 로그인한 사용자의 UID
  final String currentUserUid;

  const ClusterLabelingPage({super.key, required this.currentUserUid});

  @override
  State<ClusterLabelingPage> createState() => _ClusterLabelingPageState();
}

class _ClusterLabelingPageState extends State<ClusterLabelingPage> {
  final ClusteringService _clusteringService = ClusteringService();
  final ConnectionService _connectionService = ConnectionService();

  /// 실제 데이터를 조회할 시니어 UID (연결 검증 후 설정됨)
  String? _targetSeniorUid;
  bool _isInitializing = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeConnection();
  }

  /// 연결 검증 및 초기화
  /// 보호자 계정인 경우 연결된 시니어의 UID를 가져옵니다.
  Future<void> _initializeConnection() async {
    debugPrint('🔍 [ClusterLabeling] 연결 검증 시작: uid=${widget.currentUserUid}');

    setState(() {
      _isInitializing = true;
      _errorMessage = null;
    });

    try {
      final result = await _connectionService
          .resolveTargetSeniorUid(widget.currentUserUid)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              debugPrint('⏱️ [ClusterLabeling] 연결 검증 타임아웃');
              return ConnectionResult(
                success: false,
                message: '연결 확인 중 시간이 초과되었습니다\n네트워크를 확인해주세요',
              );
            },
          );

      debugPrint(
        '📊 [ClusterLabeling] 검증 결과: success=${result.success}, message=${result.message}',
      );

      if (!result.success) {
        setState(() {
          _errorMessage = result.message;
          _isInitializing = false;
        });
        return;
      }

      setState(() {
        _targetSeniorUid = result.targetUid;
        _isInitializing = false;
      });

      debugPrint('✅ [ClusterLabeling] 연결 검증 완료: 시니어 UID = $_targetSeniorUid');
    } catch (e, stackTrace) {
      debugPrint('❌ [ClusterLabeling] 연결 검증 에러: $e');
      debugPrint('Stack: $stackTrace');
      setState(() {
        _errorMessage = '연결 정보를 불러올 수 없습니다\n$e';
        _isInitializing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('얼굴 등록'),
        backgroundColor: Colors.deepPurple,
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 1. 초기화 중
    if (_isInitializing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('연결 정보 확인 중...'),
          ],
        ),
      );
    }

    // 2. 에러 발생 (연결 안됨, 권한 없음 등)
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.link_off, size: 80, color: Colors.orange[700]),
              const SizedBox(height: 24),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _initializeConnection,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 3. 정상: 클러스터 목록 표시
    debugPrint(
      '📊 [ClusterLabeling] StreamBuilder 시작: targetUid=$_targetSeniorUid',
    );
    return StreamBuilder<List<ClusterSuggestion>>(
      stream: _clusteringService.getClusterSuggestions(_targetSeniorUid!),
      builder: (context, snapshot) {
        debugPrint(
          '🔄 [ClusterLabeling] Stream 상태: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, hasError: ${snapshot.hasError}',
        );

        // 로딩 상태
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('얼굴 그룹을 불러오는 중...'),
              ],
            ),
          );
        }

        // 에러 상태
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                const SizedBox(height: 16),
                const Text(
                  '오류가 발생했습니다',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '${snapshot.error}',
                  style: TextStyle(color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => setState(() {}),
                  icon: const Icon(Icons.refresh),
                  label: const Text('다시 시도'),
                ),
              ],
            ),
          );
        }

        final clusters = snapshot.data ?? [];

        // 빈 상태
        if (clusters.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.face_outlined, size: 80, color: Colors.grey[400]),
                const SizedBox(height: 24),
                const Text(
                  '새로운 얼굴 제안이 없습니다',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  '일기에 등장하는 얼굴들이\n자동으로 분류됩니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        // 클러스터 목록 표시
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: clusters.length,
          itemBuilder: (context, index) {
            final cluster = clusters[index];
            return _ClusterCard(
              cluster: cluster,
              onTap: () => _navigateToDetail(cluster),
            );
          },
        );
      },
    );
  }

  /// 상세 화면으로 이동
  void _navigateToDetail(ClusterSuggestion cluster) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ClusterDetailPage(seniorUid: _targetSeniorUid!, cluster: cluster),
      ),
    );
  }
}

/// 클러스터 카드 위젯
class _ClusterCard extends StatelessWidget {
  final ClusterSuggestion cluster;
  final VoidCallback onTap;

  const _ClusterCard({required this.cluster, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 썸네일 이미지
              _buildThumbnail(),
              const SizedBox(width: 16),

              // 정보
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '이 사람은 누구인가요?',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${cluster.photoCount}장의 사진',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDarkMode ? Colors.grey[350] : Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (cluster.sampleImageUrls.isNotEmpty)
                      Text(
                        '${cluster.sampleImageUrls.length}개의 샘플 이미지',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDarkMode
                              ? Colors.grey[400]
                              : Colors.grey[500],
                        ),
                      ),
                  ],
                ),
              ),

              // 화살표 아이콘
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: isDarkMode ? Colors.grey[400] : Colors.grey[400],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    debugPrint('🖼️ [ClusterCard] 썸네일 URL: ${cluster.thumbnailUrl}');
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 80,
        height: 80,
        child: cluster.thumbnailUrl.isEmpty
            ? Container(
                color: Colors.grey[300],
                child: const Icon(Icons.person, size: 40, color: Colors.grey),
              )
            : FirebaseStorageImage(
                imageUrl: cluster.thumbnailUrl,
                fit: BoxFit.cover,
                width: 80,
                height: 80,
              ),
      ),
    );
  }
}

/// 클러스터 상세 화면
class ClusterDetailPage extends StatefulWidget {
  /// 시니어의 UID (데이터가 저장된 계정)
  final String seniorUid;
  final ClusterSuggestion cluster;

  const ClusterDetailPage({
    super.key,
    required this.seniorUid,
    required this.cluster,
  });

  @override
  State<ClusterDetailPage> createState() => _ClusterDetailPageState();
}

class _ClusterDetailPageState extends State<ClusterDetailPage> {
  final TextEditingController _nameController = TextEditingController();
  final ClusteringService _clusteringService = ClusteringService();
  final Set<String> _excludedIds = {};
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('이름 등록'),
        backgroundColor: Colors.deepPurple,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('처리 중...'),
                ],
              ),
            )
          : Column(
              children: [
                // 샘플 이미지 미리보기
                _buildSampleImagePreview(),

                // 이름 입력 섹션
                _buildNameInputSection(),

                // 안내 문구
                _buildInstructionText(),

                // 멤버 얼굴 그리드
                Expanded(child: _buildMemberGrid()),

                // 하단 버튼
                _buildBottomActions(),
              ],
            ),
    );
  }

  /// 샘플 이미지 미리보기 (가로 스크롤)
  Widget _buildSampleImagePreview() {
    if (widget.cluster.sampleImageUrls.isEmpty) {
      return const SizedBox.shrink();
    }

    debugPrint(
      '🖼️ [ClusterDetail] 샘플 이미지 개수: ${widget.cluster.sampleImageUrls.length}',
    );
    return Container(
      height: 120,
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: widget.cluster.sampleImageUrls.length,
        itemBuilder: (context, index) {
          final url = widget.cluster.sampleImageUrls[index];
          debugPrint('🖼️ [ClusterDetail] 샘플[$index] URL: $url');
          return Container(
            width: 100,
            margin: const EdgeInsets.only(right: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: FirebaseStorageImage(
                imageUrl: url,
                fit: BoxFit.cover,
                width: 100,
                height: 120,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 이름 입력 섹션
  Widget _buildNameInputSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.deepPurple.withOpacity(0.05),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: '이름을 입력하세요 (예: 할머니, 친구)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.person_outline),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _confirmLabel(),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _confirmLabel,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              '등록',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 안내 문구
  Widget _buildInstructionText() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '잘못 포함된 얼굴은 터치하여 제외할 수 있습니다',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// 멤버 얼굴 그리드
  Widget _buildMemberGrid() {
    final validMembers = widget.cluster.members
        .where((m) => m.isValid)
        .toList();

    if (validMembers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('얼굴 이미지가 없습니다', style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: validMembers.length,
      itemBuilder: (context, index) {
        final member = validMembers[index];
        final isExcluded = _excludedIds.contains(member.id);
        debugPrint('🖼️ [ClusterDetail] 멤버[$index] URL: ${member.faceUrl}');

        return GestureDetector(
          onTap: () {
            setState(() {
              if (isExcluded) {
                _excludedIds.remove(member.id);
              } else {
                _excludedIds.add(member.id);
              }
            });
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 얼굴 이미지
                FirebaseStorageImage(
                  imageUrl: member.faceUrl,
                  fit: BoxFit.cover,
                ),

                // 제외 표시
                if (isExcluded)
                  Container(
                    color: Colors.white.withOpacity(0.7),
                    child: const Center(
                      child: Icon(Icons.close, color: Colors.red, size: 48),
                    ),
                  )
                else
                  const Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 24,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 하단 액션 버튼
  Widget _buildBottomActions() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: TextButton.icon(
          onPressed: _rejectCluster,
          icon: Icon(
            Icons.cancel_outlined,
            color: isDarkMode ? Colors.redAccent.shade200 : Colors.red,
          ),
          label: Text(
            '잘못 묶인 그룹입니다 (해체하기)',
            style: TextStyle(
              color: isDarkMode ? Colors.redAccent.shade200 : Colors.red,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }

  /// 라벨 확정 (이름 등록)
  Future<void> _confirmLabel() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      _showSnackBar('이름을 입력해주세요', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    final result = await _clusteringService.registerFaceLabel(
      uid: widget.seniorUid,
      groupId: widget.cluster.groupId,
      name: name,
      excludeFaceIds: _excludedIds.isNotEmpty ? _excludedIds.toList() : null,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.success) {
      _showSnackBar('✅ ${result.message}', isError: false);
      Navigator.pop(context);
    } else {
      _showSnackBar('❌ ${result.message}', isError: true);
    }
  }

  /// 클러스터 거부
  Future<void> _rejectCluster() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('그룹 해체'),
        content: const Text('이 그룹을 해체하시겠습니까?\n얼굴들은 다시 분석 대상이 됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('해체'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    final result = await _clusteringService.rejectClusterSuggestion(
      uid: widget.seniorUid,
      groupId: widget.cluster.groupId,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.success) {
      _showSnackBar('✅ ${result.message}', isError: false);
      Navigator.pop(context);
    } else {
      _showSnackBar('❌ ${result.message}', isError: true);
    }
  }

  /// 스낵바 표시
  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

/// Firebase Storage 이미지 위젯
/// gs:// URL을 자동으로 https:// 다운로드 URL로 변환합니다.
class FirebaseStorageImage extends StatefulWidget {
  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;

  const FirebaseStorageImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  @override
  State<FirebaseStorageImage> createState() => _FirebaseStorageImageState();
}

class _FirebaseStorageImageState extends State<FirebaseStorageImage> {
  String? _downloadUrl;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _resolveUrl();
  }

  @override
  void didUpdateWidget(FirebaseStorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _resolveUrl();
    }
  }

  /// gs:// URL 또는 https://storage.googleapis.com/ URL을 다운로드 URL로 변환
  Future<void> _resolveUrl() async {
    if (widget.imageUrl.isEmpty) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      String downloadUrl;

      // gs:// 스키마인 경우 Firebase Storage에서 다운로드 URL 가져오기
      if (widget.imageUrl.startsWith('gs://')) {
        debugPrint(
          '🔄 [FirebaseStorageImage] gs:// URL 변환 시작: ${widget.imageUrl}',
        );
        final ref = FirebaseStorage.instance.refFromURL(widget.imageUrl);
        downloadUrl = await ref.getDownloadURL();
        debugPrint('✅ [FirebaseStorageImage] 다운로드 URL: $downloadUrl');
      }
      // https://storage.googleapis.com/ URL인 경우도 변환 필요
      else if (widget.imageUrl.contains('storage.googleapis.com/')) {
        debugPrint(
          '🔄 [FirebaseStorageImage] storage.googleapis.com URL 변환 시작: ${widget.imageUrl}',
        );
        // URL에서 버킷과 경로 추출
        // 형식: https://storage.googleapis.com/BUCKET_NAME/PATH
        final uri = Uri.parse(widget.imageUrl);
        final pathSegments = uri.pathSegments;
        if (pathSegments.isNotEmpty) {
          final bucketName = pathSegments.first;
          // URL 디코딩 처리 (한글, 공백, 특수문자 대응)
          final objectPath = Uri.decodeComponent(
            pathSegments.skip(1).join('/'),
          );
          // gs:// URL로 변환 후 다운로드 URL 획득
          final gsUrl = 'gs://$bucketName/$objectPath';
          debugPrint('🔄 [FirebaseStorageImage] 변환된 gs:// URL: $gsUrl');
          final ref = FirebaseStorage.instance.refFromURL(gsUrl);
          downloadUrl = await ref.getDownloadURL();
          debugPrint('✅ [FirebaseStorageImage] 다운로드 URL: $downloadUrl');
        } else {
          downloadUrl = widget.imageUrl;
        }
      }
      // 이미 firebasestorage.googleapis.com 다운로드 URL인 경우 그대로 사용
      else if (widget.imageUrl.contains('firebasestorage.googleapis.com')) {
        downloadUrl = widget.imageUrl;
      }
      // 기타 https:// URL은 그대로 사용
      else {
        downloadUrl = widget.imageUrl;
      }

      if (mounted) {
        setState(() {
          _downloadUrl = downloadUrl;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ [FirebaseStorageImage] URL 변환 실패: $e');
      debugPrint('❌ [FirebaseStorageImage] 원본 URL: ${widget.imageUrl}');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[200],
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_hasError || _downloadUrl == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[300],
        child: const Icon(Icons.broken_image, color: Colors.grey),
      );
    }

    return CachedNetworkImage(
      imageUrl: _downloadUrl!,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      placeholder: (context, url) => Container(
        color: Colors.grey[200],
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      errorWidget: (context, url, error) => Container(
        color: Colors.grey[300],
        child: const Icon(Icons.broken_image, color: Colors.grey),
      ),
    );
  }
}
