import '../../../../core/error/app_failure.dart';
import '../../../../core/network/nas_api_client.dart';
import '../../../../core/path/nas_path.dart';
import '../../../../core/protocol/file_protocol_client.dart';
import '../../../../core/result/app_result.dart';
import '../../application/params/list_directory_params.dart';
import '../../domain/entities/batch_delete_result_entity.dart';
import '../../domain/entities/file_category.dart';
import '../../domain/entities/file_entry_entity.dart';
import '../../domain/entities/file_list_page_entity.dart';
import '../../domain/entities/file_type.dart';
import '../../domain/repositories/file_repository.dart';

class FileRepositoryImpl implements FileRepository {
  FileRepositoryImpl({
    required FileProtocolClient protocolClient,
    required NasApiClient apiClient,
  }) : _protocolClient = protocolClient,
       _apiClient = apiClient;

  static const int _maxBatchDeleteSize = 100;

  final FileProtocolClient _protocolClient;
  final NasApiClient _apiClient;

  @override
  Future<AppResult<FileListPageEntity>> listDirectory(
    ListDirectoryParams params,
  ) async {
    if (params.folderView) {
      return _listFolder(params);
    }
    try {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/api/v1/files/list',
        queryParameters: {
          'rootId': params.path.rootId,
          'path': params.path.path,
          'limit': params.limit,
          'category': params.category.name,
          if (params.cursor != null && params.cursor!.isNotEmpty)
            'cursor': params.cursor,
          if (params.sortBy != null) 'sortBy': params.sortBy,
          if (params.sortOrder != null) 'sortOrder': params.sortOrder,
        },
      );

      final items = ((response['items'] as List?) ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(_mapFileEntry)
          .toList(growable: false);
      return Success(
        FileListPageEntity(
          items: items,
          hasMore: response['hasMore'] == true,
          nextCursor: response['nextCursor'] as String?,
        ),
      );
    } catch (_) {
      try {
        final files = await _protocolClient.listDirectory(params.path);
        final filtered = _filterFiles(files, params.category);
        final offset = _parseCursor(params.cursor);
        final start = offset.clamp(0, filtered.length);
        final end = (start + params.limit).clamp(0, filtered.length);
        final items = filtered.sublist(start, end);
        final hasMore = end < filtered.length;
        return Success(
          FileListPageEntity(
            items: items,
            hasMore: hasMore,
            nextCursor: hasMore ? '$end' : null,
          ),
        );
      } catch (e) {
        return Failure(
          AppFailure.fromException(
            code: 'LIST_ERROR',
            message: 'Failed to list directory: ${e.toString()}',
          ),
        );
      }
    }
  }

  /// 文件夹视图：WebDAV 列出当前目录，文件夹在前，其余按排序设置。
  Future<AppResult<FileListPageEntity>> _listFolder(
    ListDirectoryParams params,
  ) async {
    try {
      final entries = await _protocolClient.listDirectory(params.path);
      final sorted = sortFolderEntries(
        entries,
        sortBy: params.sortBy,
        sortOrder: params.sortOrder,
      );
      final offset = _parseCursor(params.cursor);
      final start = offset.clamp(0, sorted.length);
      final end = (start + params.limit).clamp(0, sorted.length);
      final hasMore = end < sorted.length;
      return Success(
        FileListPageEntity(
          items: sorted.sublist(start, end),
          hasMore: hasMore,
          nextCursor: hasMore ? '$end' : null,
        ),
      );
    } catch (e) {
      return Failure(
        AppFailure.fromException(
          code: 'LIST_ERROR',
          message: 'Failed to list directory: ${e.toString()}',
        ),
      );
    }
  }

  static List<FileEntryEntity> sortFolderEntries(
    List<FileEntryEntity> entries, {
    String? sortBy,
    String? sortOrder,
  }) {
    final ascending = sortOrder == 'asc';
    int compareValue(FileEntryEntity a, FileEntryEntity b) {
      if (sortBy == 'size' && a.isFile && b.isFile) {
        return a.size.compareTo(b.size);
      }
      if (sortBy == 'name' || (sortBy == 'size' && !a.isFile)) {
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      final am = a.modifiedAt?.millisecondsSinceEpoch ?? 0;
      final bm = b.modifiedAt?.millisecondsSinceEpoch ?? 0;
      return am.compareTo(bm);
    }

    final list = List<FileEntryEntity>.from(entries);
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      // 文件夹始终按名称升序，方便查找
      if (a.isDirectory) {
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      final c = compareValue(a, b);
      if (c != 0) return ascending ? c : -c;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  @override
  Future<AppResult<void>> moveEntry(NasPath from, NasPath to) async {
    try {
      await _protocolClient.move(from, to);
      return const Success(null);
    } catch (e) {
      return Failure(
        AppFailure.fromException(
          code: 'MOVE_ERROR',
          message: 'Failed to move: ${e.toString()}',
        ),
      );
    }
  }

  @override
  Future<AppResult<void>> createFolder(NasPath path) async {
    try {
      await _protocolClient.createDirectory(path);
      return const Success(null);
    } catch (e) {
      return Failure(
        AppFailure.fromException(
          code: 'CREATE_FOLDER_ERROR',
          message: 'Failed to create folder: ${e.toString()}',
        ),
      );
    }
  }

  @override
  Future<AppResult<void>> deleteFile(NasPath path) async {
    try {
      await _protocolClient.delete(path);
      return const Success(null);
    } catch (e) {
      return Failure(
        AppFailure.fromException(
          code: 'DELETE_ERROR',
          message: 'Failed to delete file: ${e.toString()}',
        ),
      );
    }
  }

  @override
  Future<AppResult<List<BatchDeleteResultEntity>>> batchDelete(
    List<NasPath> paths,
  ) async {
    if (paths.isEmpty) {
      return const Success(<BatchDeleteResultEntity>[]);
    }

    try {
      final results = <BatchDeleteResultEntity>[];
      final apiPaths = paths
          .map((path) {
            final relative = path.path == '/' ? '' : path.path;
            final parts = relative
                .split('/')
                .where((segment) => segment.isNotEmpty)
                .map(Uri.encodeComponent)
                .toList(growable: false);
            final encodedRelative = parts.isEmpty ? '' : '/${parts.join('/')}';
            return '/${path.rootId}$encodedRelative';
          })
          .toList(growable: false);

      for (
        var start = 0;
        start < apiPaths.length;
        start += _maxBatchDeleteSize
      ) {
        final end = start + _maxBatchDeleteSize > apiPaths.length
            ? apiPaths.length
            : start + _maxBatchDeleteSize;
        final response = await _apiClient.post<Map<String, dynamic>>(
          '/api/v1/files/batch-delete',
          data: {'paths': apiPaths.sublist(start, end)},
        );
        final resultsJson = (response['results'] as List?) ?? const [];
        results.addAll(
          resultsJson
              .map(
                (e) =>
                    BatchDeleteResultEntity.fromJson(e as Map<String, dynamic>),
              )
              .toList(),
        );
      }

      return Success(results);
    } catch (e) {
      return Failure(
        AppFailure.fromException(
          code: 'BATCH_DELETE_ERROR',
          message: 'Failed to batch delete: ${e.toString()}',
        ),
      );
    }
  }

  FileEntryEntity _mapFileEntry(Map<String, dynamic> json) {
    final modifiedAtRaw = json['modifiedAt'] as String?;
    return FileEntryEntity(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      type: json['type'] == 'directory' ? FileType.directory : FileType.file,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: modifiedAtRaw == null
          ? null
          : DateTime.tryParse(modifiedAtRaw)?.toLocal(),
    );
  }

  List<FileEntryEntity> _filterFiles(
    List<FileEntryEntity> files,
    FileCategory category,
  ) {
    return files
        .where((file) {
          if (file.isDirectory) {
            return false;
          }
          final resolvedCategory = FileCategory.fromExtension(file.extension);
          return switch (category) {
            FileCategory.other => resolvedCategory == null,
            _ => resolvedCategory == category,
          };
        })
        .toList(growable: false);
  }

  int _parseCursor(String? cursor) {
    if (cursor == null || cursor.isEmpty) {
      return 0;
    }
    final parsed = int.tryParse(cursor);
    if (parsed == null || parsed < 0) {
      return 0;
    }
    return parsed;
  }
}
