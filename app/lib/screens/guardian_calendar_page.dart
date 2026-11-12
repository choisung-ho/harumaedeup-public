// lib/screens/guardian_calendar_page.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../theme_state.dart'; // 테마 시스템

class GuardianCalendarPage extends StatefulWidget {
  final String patientId;
  final String patientName;

  const GuardianCalendarPage({
    super.key,
    required this.patientId,
    required this.patientName,
  });

  @override
  State<GuardianCalendarPage> createState() => _GuardianCalendarPageState();
}

class _GuardianCalendarPageState extends State<GuardianCalendarPage> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  List<File> _tempImages = [];
  File? _tempVideo;
  bool _isUploading = false;

  final PageController _pageController = PageController(viewportFraction: 0.85);

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  bool _isFutureDate(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);
    return target.isAfter(today);
  }

  // ===========================================================================
  // 📸 미디어 선택 및 저장/수정 로직
  // ===========================================================================

  Future<void> _pickImages(StateSetter setModalState) async {
    try {
      final List<XFile> images = await _picker.pickMultiImage();
      if (images.isNotEmpty) {
        setModalState(() {
          _tempImages.addAll(images.map((e) => File(e.path)));
        });
      }
    } catch (e) {
      debugPrint("사진 선택 오류: $e");
    }
  }

  Future<void> _pickVideo(StateSetter setModalState) async {
    try {
      final XFile? video = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (video != null) {
        setModalState(() {
          _tempVideo = File(video.path);
        });
      }
    } catch (e) {
      debugPrint("영상 선택 오류: $e");
    }
  }

  Future<void> _saveLog(StateSetter setModalState) async {
    if (_titleController.text.isEmpty &&
        _contentController.text.isEmpty &&
        _tempImages.isEmpty &&
        _tempVideo == null) {
      return;
    }

    setModalState(() => _isUploading = true);

    try {
      List<String> imageUrls = [];
      String? videoUrl;

      for (var file in _tempImages) {
        String fileName =
            'diaries/${widget.patientId}/img_${DateTime.now().millisecondsSinceEpoch}_${_tempImages.indexOf(file)}.jpg';
        TaskSnapshot upload = await FirebaseStorage.instance
            .ref(fileName)
            .putFile(file);
        imageUrls.add(await upload.ref.getDownloadURL());
      }

      if (_tempVideo != null) {
        String fileName =
            'diaries/${widget.patientId}/vid_${DateTime.now().millisecondsSinceEpoch}.mp4';
        TaskSnapshot upload = await FirebaseStorage.instance
            .ref(fileName)
            .putFile(_tempVideo!);
        videoUrl = await upload.ref.getDownloadURL();
      }

      final saveDate = DateTime(
        _selectedDay!.year,
        _selectedDay!.month,
        _selectedDay!.day,
        12,
        0,
        0,
      );

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.patientId)
          .collection('patient_logs')
          .add({
            'title': _titleController.text,
            'content': _contentController.text,
            'date': Timestamp.fromDate(saveDate),
            'imageUrls': imageUrls,
            'videoUrl': videoUrl,
            'createdAt': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("일지가 저장되었습니다"),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      debugPrint("저장 실패: $e");
      if (mounted) {
        setModalState(() => _isUploading = false);
      }
    } finally {
      if (mounted) _resetForm();
    }
  }

  Future<void> _updateLog({
    required String docId,
    required String title,
    required String content,
    required List<String> keptImageUrls,
    required List<File> newImageFiles,
    required String? keptVideoUrl,
    required File? newVideoFile,
    required StateSetter setModalState,
  }) async {
    setModalState(() => _isUploading = true);

    try {
      List<String> finalImageUrls = [...keptImageUrls];
      String? finalVideoUrl = keptVideoUrl;

      for (var file in newImageFiles) {
        String fileName =
            'diaries/${widget.patientId}/img_edit_${DateTime.now().millisecondsSinceEpoch}_${newImageFiles.indexOf(file)}.jpg';
        TaskSnapshot upload = await FirebaseStorage.instance
            .ref(fileName)
            .putFile(file);
        finalImageUrls.add(await upload.ref.getDownloadURL());
      }

      if (newVideoFile != null) {
        String fileName =
            'diaries/${widget.patientId}/vid_edit_${DateTime.now().millisecondsSinceEpoch}.mp4';
        TaskSnapshot upload = await FirebaseStorage.instance
            .ref(fileName)
            .putFile(newVideoFile);
        finalVideoUrl = await upload.ref.getDownloadURL();
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.patientId)
          .collection('patient_logs')
          .doc(docId)
          .update({
            'title': title,
            'content': content,
            'imageUrls': finalImageUrls,
            'videoUrl': finalVideoUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("수정되었습니다"),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      debugPrint("수정 실패: $e");
      if (mounted) setModalState(() => _isUploading = false);
    } finally {
      if (mounted) _isUploading = false;
    }
  }

  Future<void> _deleteLog(DocumentSnapshot doc) async {
    bool? confirm = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("일지 삭제"),
        content: const Text("정말 삭제하시겠습니까?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("삭제", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await doc.reference.delete();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("삭제되었습니다")));
      }
    }
  }

  void _resetForm() {
    setState(() {
      _tempImages = [];
      _tempVideo = null;
      _titleController.clear();
      _contentController.clear();
      _isUploading = false;
    });
  }

  // 📝 작성/수정 바텀 시트
  void _showAddLogSheet() {
    if (_selectedDay != null && _isFutureDate(_selectedDay!)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("미래의 날짜에는 일지를 작성할 수 없습니다.")));
      return;
    }

    _resetForm();
    _showLogSheetInternal(isEdit: false);
  }

  void _showEditLogSheet(DocumentSnapshot doc) {
    Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
    _titleController.text = data['title'] ?? "";
    _contentController.text = data['content'] ?? "";
    _showLogSheetInternal(
      isEdit: true,
      docId: doc.id,
      initialImages: List<String>.from(data['imageUrls'] ?? []),
      initialVideo: data['videoUrl'],
    );
  }

  void _showLogSheetInternal({
    required bool isEdit,
    String? docId,
    List<String> initialImages = const [],
    String? initialVideo,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBgColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black;
    final subtextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : Colors.grey[600];
    final inputBgColor = isDark ? AppColors.darkBackground : Colors.grey[50];
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF81C784);

    List<String> keptImages = List.from(initialImages);
    String? keptVideo = initialVideo;
    List<File> newImages = [];
    File? newVideo;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          decoration: BoxDecoration(
            color: sheetBgColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isEdit ? Icons.edit : Icons.edit_note_rounded,
                      color: accentColor,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isEdit ? "일지 수정" : "일지 작성",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _titleController,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                  decoration: InputDecoration(
                    hintText: "제목",
                    hintStyle: TextStyle(
                      color: subtextColor?.withOpacity(0.6),
                      fontWeight: FontWeight.bold,
                    ),
                    filled: true,
                    fillColor: inputBgColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contentController,
                  maxLines: 6,
                  style: TextStyle(color: textColor),
                  decoration: InputDecoration(
                    hintText: "오늘의 관찰 기록을 작성해주세요...",
                    hintStyle: TextStyle(color: subtextColor?.withOpacity(0.6)),
                    filled: true,
                    fillColor: inputBgColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _buildMediaButton(
                        icon: Icons.photo,
                        label: "사진",
                        color: Colors.orange,
                        isDark: isDark,
                        onTap: () async {
                          final pics = await _picker.pickMultiImage();
                          if (pics.isNotEmpty)
                            setModalState(
                              () => isEdit
                                  ? newImages.addAll(
                                      pics.map((e) => File(e.path)),
                                    )
                                  : _tempImages.addAll(
                                      pics.map((e) => File(e.path)),
                                    ),
                            );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildMediaButton(
                        icon: Icons.videocam,
                        label: "영상",
                        color: Colors.blue,
                        isDark: isDark,
                        onTap: () async {
                          final vid = await _picker.pickVideo(
                            source: ImageSource.gallery,
                            maxDuration: const Duration(minutes: 5),
                          );
                          if (vid != null)
                            setModalState(
                              () => isEdit
                                  ? newVideo = File(vid.path)
                                  : _tempVideo = File(vid.path),
                            );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isEdit && keptImages.isNotEmpty)
                  SizedBox(
                    height: 60,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: keptImages.length,
                      itemBuilder: (c, i) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Image.network(
                          keptImages[i],
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                if ((isEdit ? newImages : _tempImages).isNotEmpty)
                  SizedBox(
                    height: 60,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: (isEdit ? newImages : _tempImages).length,
                      itemBuilder: (c, i) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Image.file(
                          (isEdit ? newImages : _tempImages)[i],
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),

                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isUploading
                        ? null
                        : () {
                            if (isEdit) {
                              _updateLog(
                                docId: docId!,
                                title: _titleController.text,
                                content: _contentController.text,
                                keptImageUrls: keptImages,
                                newImageFiles: newImages,
                                keptVideoUrl: keptVideo,
                                newVideoFile: newVideo,
                                setModalState: setModalState,
                              );
                            } else {
                              _saveLog(setModalState);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accentColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _isUploading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(
                            isEdit ? "수정 완료" : "저장하기",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMediaButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? color.withOpacity(0.15) : color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 🎨 메인 화면 UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? AppColors.darkBackground
        : const Color(0xFFF8F9FA);
    final surfaceColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black;
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF81C784);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          "${widget.patientName}님 관찰 일지",
          style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        backgroundColor: surfaceColor,
        foregroundColor: textColor,
        elevation: 0,
        // ✅ [추가] 검색 버튼
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              showSearch(
                context: context,
                delegate: LogSearchDelegate(
                  patientId: widget.patientId,
                  isDark: isDark,
                ),
              );
            },
          ),
        ],
      ),
      // ✅ [수정] 미래 날짜가 아닐 때만 플로팅 버튼 표시
      floatingActionButton:
          (_selectedDay != null && !_isFutureDate(_selectedDay!))
          ? FloatingActionButton.extended(
              onPressed: _showAddLogSheet,
              backgroundColor: accentColor,
              icon: const Icon(Icons.edit, color: Colors.white),
              label: const Text(
                "일지 작성",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null, // 미래 날짜면 버튼 숨김
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.patientId)
            .collection('patient_logs')
            .orderBy('date', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final allDocs = snapshot.data?.docs ?? [];

          List<DocumentSnapshot> getEventsForDay(DateTime day) {
            return allDocs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              if (data['date'] == null) return false;
              final date = (data['date'] as Timestamp).toDate();
              return isSameDay(date, day);
            }).toList();
          }

          final selectedDayLogs = getEventsForDay(
            _selectedDay ?? DateTime.now(),
          );

          return Column(
            children: [
              Container(
                color: surfaceColor,
                padding: const EdgeInsets.only(bottom: 10),
                child: TableCalendar(
                  locale: 'ko_KR',
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2030, 12, 31),
                  focusedDay: _focusedDay,
                  selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                  onDaySelected: (selectedDay, focusedDay) {
                    setState(() {
                      _selectedDay = selectedDay;
                      _focusedDay = focusedDay;
                    });
                  },
                  eventLoader: getEventsForDay,
                  // ✅ [수정] 미래 날짜 선택 불가 (enabledDayPredicate 추가)
                  enabledDayPredicate: (day) => !_isFutureDate(day),

                  rowHeight: 42,
                  daysOfWeekHeight: 22,
                  headerStyle: const HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                  ),
                  calendarStyle: CalendarStyle(
                    todayDecoration: BoxDecoration(
                      color: accentColor.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    selectedDecoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                    markerDecoration: const BoxDecoration(
                      color: Color(0xFF81C784),
                      shape: BoxShape.circle,
                    ),
                    markersMaxCount: 1,
                    // 비활성화된 날짜 스타일 (흐리게)
                    disabledTextStyle: const TextStyle(color: Colors.grey),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              Expanded(
                child: selectedDayLogs.isEmpty
                    ? Center(
                        child: Text(
                          (_selectedDay != null && _isFutureDate(_selectedDay!))
                              ? "미래의 일지는 작성할 수 없습니다."
                              : "작성된 일지가 없습니다.",
                          style: TextStyle(color: textColor.withOpacity(0.5)),
                        ),
                      )
                    : PageView.builder(
                        controller: _pageController,
                        scrollDirection: Axis.horizontal,
                        itemCount: selectedDayLogs.length,
                        itemBuilder: (context, index) {
                          return _buildLogCardItem(
                            selectedDayLogs[index],
                            isDark,
                            textColor,
                            accentColor,
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ✅ [수정됨] 카드 디자인 변경: 시간 제거하고 제목만 표시
  Widget _buildLogCardItem(
    DocumentSnapshot doc,
    bool isDark,
    Color textColor,
    Color accentColor,
  ) {
    final data = doc.data() as Map<String, dynamic>;
    final title = data['title'] ?? "";
    final List<dynamic> images = data['imageUrls'] ?? [];
    final String? video = data['videoUrl'];

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => LogDetailPage(
              patientId: widget.patientId,
              docId: doc.id,
              isDark: isDark,
              onEditCallback: () => _showEditLogSheet(doc),
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 미디어 (사진/동영상) 영역
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                child: Container(
                  color: isDark ? Colors.black26 : Colors.grey[100],
                  child: images.isNotEmpty
                      ? Image.network(images.first, fit: BoxFit.cover)
                      : video != null
                      ? Center(
                          child: Icon(
                            Icons.play_circle_filled,
                            size: 64,
                            color: accentColor.withOpacity(0.5),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.article,
                            size: 64,
                            color: Colors.grey[300],
                          ),
                        ),
                ),
              ),
            ),

            // 2. 제목 표시 영역
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurface : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(24),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title.isNotEmpty ? title : "제목 없음",
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                  if (images.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        "+${images.length - 1}",
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 🔎 [NEW] 검색 로직 (LogSearchDelegate)
// =============================================================================
class LogSearchDelegate extends SearchDelegate {
  final String patientId;
  final bool isDark;

  LogSearchDelegate({required this.patientId, required this.isDark});

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, null);
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildSearchList();

  @override
  Widget buildSuggestions(BuildContext context) => _buildSearchList();

  Widget _buildSearchList() {
    if (query.isEmpty) {
      return const Center(
        child: Text("제목을 입력하여 검색하세요.", style: TextStyle(color: Colors.grey)),
      );
    }

    final textColor = isDark ? AppColors.darkOnSurface : Colors.black;
    final accentColor = isDark
        ? AppColors.darkPrimary
        : const Color(0xFF81C784);

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(patientId)
          .collection('patient_logs')
          .orderBy('date', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());

        final allDocs = snapshot.data!.docs;
        final filteredDocs = allDocs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final title = (data['title'] ?? "").toString();
          return title.toLowerCase().contains(query.toLowerCase());
        }).toList();

        if (filteredDocs.isEmpty) {
          return const Center(child: Text("검색 결과가 없습니다."));
        }

        return ListView.builder(
          itemCount: filteredDocs.length,
          itemBuilder: (context, index) {
            final doc = filteredDocs[index];
            final data = doc.data() as Map<String, dynamic>;
            final title = data['title'] ?? "제목 없음";
            final dateTs = data['date'] as Timestamp?;
            final dateStr = dateTs != null
                ? DateFormat('yyyy.MM.dd').format(dateTs.toDate())
                : "";

            return ListTile(
              title: Text(
                title,
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                dateStr,
                style: const TextStyle(color: Colors.grey),
              ),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.article_rounded, color: accentColor),
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => LogDetailPage(
                      patientId: patientId,
                      docId: doc.id,
                      isDark: isDark,
                      onEditCallback: () {
                        // 검색 화면 닫고 알림
                        Navigator.pop(context);
                        close(context, null);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("수정은 캘린더 화면에서 가능합니다.")),
                        );
                      },
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class LogDetailPage extends StatelessWidget {
  final String patientId;
  final String docId;
  final bool isDark;
  final VoidCallback onEditCallback;

  const LogDetailPage({
    super.key,
    required this.patientId,
    required this.docId,
    required this.isDark,
    required this.onEditCallback,
  });

  Future<void> _deleteLog(BuildContext context) async {
    bool? confirm = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("일지 삭제"),
        content: const Text("정말 삭제하시겠습니까?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("삭제", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(patientId)
          .collection('patient_logs')
          .doc(docId)
          .delete();

      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("삭제되었습니다")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black;
    final backgroundColor = isDark
        ? AppColors.darkBackground
        : const Color(0xFFF8F9FA);

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(patientId)
          .collection('patient_logs')
          .doc(docId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return Scaffold(backgroundColor: backgroundColor);
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;
        final title = data['title'] ?? "";
        final content = data['content'] ?? "";
        final List<dynamic> images = data['imageUrls'] ?? [];
        final String? video = data['videoUrl'];
        final Timestamp? createdAt = data['createdAt'];

        return Scaffold(
          backgroundColor: backgroundColor,
          appBar: AppBar(
            backgroundColor: backgroundColor,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new, color: textColor),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                onPressed: onEditCallback,
                icon: const Icon(Icons.edit, color: Colors.blue),
              ),
              IconButton(
                onPressed: () => _deleteLog(context),
                icon: const Icon(Icons.delete, color: Colors.red),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (createdAt != null)
                  Text(
                    DateFormat(
                      'yyyy년 M월 d일 a h:mm',
                      'ko_KR',
                    ).format(createdAt.toDate()),
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                const SizedBox(height: 16),

                if (title.isNotEmpty)
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                const SizedBox(height: 20),

                Text(
                  content,
                  style: TextStyle(color: textColor, fontSize: 16, height: 1.6),
                ),
                const SizedBox(height: 30),

                if (images.isNotEmpty)
                  ...images.map(
                    (url) => Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FullScreenImagePage(imageUrl: url),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.network(
                            url,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),

                if (video != null)
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SimpleVideoPlayerPage(videoUrl: video),
                      ),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                          size: 64,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 50),
              ],
            ),
          ),
        );
      },
    );
  }
}

class FullScreenImagePage extends StatelessWidget {
  final String imageUrl;
  const FullScreenImagePage({super.key, required this.imageUrl});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(child: InteractiveViewer(child: Image.network(imageUrl))),
    );
  }
}

class SimpleVideoPlayerPage extends StatefulWidget {
  final String videoUrl;
  const SimpleVideoPlayerPage({super.key, required this.videoUrl});
  @override
  State<SimpleVideoPlayerPage> createState() => _SimpleVideoPlayerPageState();
}

class _SimpleVideoPlayerPageState extends State<SimpleVideoPlayerPage> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl))
      ..initialize().then((_) {
        setState(() => _isInitialized = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _isInitialized
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
