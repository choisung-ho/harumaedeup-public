// recording_list_page.dart

import 'dart:io'; // 파일 시스템 접근용
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart'; // 날짜 포맷용

class RecordingListPage extends StatefulWidget {
  const RecordingListPage({super.key});

  @override
  State<RecordingListPage> createState() => _RecordingListPageState();
}

class _RecordingListPageState extends State<RecordingListPage> {
  List<FileSystemEntity> _recordingFiles = [];
  String? _folderPath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRecordings();
    });
  }

  Future<void> _loadRecordings() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    final prefs = await SharedPreferences.getInstance();
    _folderPath = prefs.getString('recording_folder_path');

    if (_folderPath != null) {
      final dir = Directory(_folderPath!);

      if (await dir.exists()) {
        List<FileSystemEntity> files = dir.listSync();

        var audioFiles = files.where((file) {
          final ext = file.path.split('.').last.toLowerCase();
          return ['m4a', 'mp3', 'amr', 'wav'].contains(ext);
        }).toList();

        audioFiles.sort((a, b) {
          return b.statSync().modified.compareTo(a.statSync().modified);
        });

        if (mounted) {
          setState(() {
            _recordingFiles = audioFiles;
          });
        }
      }
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }

  void _onAnalyzeTap(FileSystemEntity file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("통화 내용 분석"),
        content: Text("이 녹음 파일을 분석하여\n요약하시겠습니까?\n\n파일: ${file.path.split('/').last}"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("분석 요청이 시작되었습니다.")));
            },
            child: const Text("분석 시작", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
          ),
        ],
      ),
    );
  }

  Widget _buildBodyContent(bool isDark) {
    if (_folderPath == null) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        alignment: Alignment.center,
        child: const Text("연결된 폴더가 없습니다."),
      );
    }

    if (_recordingFiles.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight,
                minWidth: constraints.maxWidth,
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.folder_off, size: 50, color: Colors.grey),
                    SizedBox(height: 10),
                    Text("폴더에 녹음 파일이 없습니다.", style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: _recordingFiles.length,
      separatorBuilder: (ctx, i) => const Divider(),
      itemBuilder: (context, index) {
        final file = _recordingFiles[index];
        final stat = file.statSync();
        final fileName = file.path.split('/').last;

        return ListTile(
          leading: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic, color: Colors.blue),
          ),
          title: Text(
            fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black),
          ),
          subtitle: Text(
            "${DateFormat('yyyy.MM.dd HH:mm').format(stat.modified)}  •  ${_formatFileSize(stat.size)}",
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          trailing: ElevatedButton(
            onPressed: () => _onAnalyzeTap(file),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: const Text("분석", style: TextStyle(fontSize: 12)),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text("통화 녹음 목록"),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // 1층: 실제 화면
          Positioned.fill(
            child: RefreshIndicator(
              onRefresh: _loadRecordings,
              child: _buildBodyContent(isDark),
            ),
          ),

          // 2층: 로딩바 (투명 배경)
          if (_isLoading)
            const Positioned.fill(
              // 👇 [수정] 배경색을 없애고(투명) 뺑글이만 띄웁니다!
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
