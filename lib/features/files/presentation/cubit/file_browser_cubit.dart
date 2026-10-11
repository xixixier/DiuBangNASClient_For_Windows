import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/path/nas_path.dart';
import '../../../../core/result/app_result.dart';
import '../../application/params/list_directory_params.dart';
import '../../application/params/load_visible_thumbnails_params.dart';
import '../../application/use_cases/batch_delete_use_case.dart';
import '../../application/use_cases/create_folder_use_case.dart';
import '../../application/use_cases/delete_file_use_case.dart';
import '../../application/use_cases/get_cached_thumbnail_use_case.dart';
import '../../application/use_cases/is_root_writable_use_case.dart';
import '../../application/use_cases/list_directory_use_case.dart';
import '../../application/use_cases/load_visible_thumbnails_use_case.dart';
import '../../application/use_cases/move_entry_use_case.dart';
import '../../application/use_cases/switch_file_root_use_case.dart';
import '../../domain/entities/batch_delete_result_entity.dart';
import '../../domain/entities/file_category.dart';
import '../../domain/entities/file_entry_entity.dart';
import '../../domain/entities/file_type.dart';
import '../../domain/entities/file_list_page_entity.dart';
import 'file_browser_state.dart';

class FileBrowserCubit extends Cubit<FileBrowserState> {
  FileBrowserCubit({
    required ListDirectoryUseCase listDirectoryUseCase,
    required CreateFolderUseCase createFolderUseCase,
    required DeleteFileUseCase deleteFileUseCase,
    required BatchDeleteUseCase batchDeleteUseCase,
    required LoadVisibleThumbnailsUseCase loadVisibleThumbnailsUseCase,
    required GetCachedThumbnailUseCase getCachedThumbnailUseCase,
    required SwitchFileRootUseCase switchFileRootUseCase,
    required IsRootWritableUseCase isRootWritableUseCase,
    MoveEntryUseCase? moveEntryUseCase,
  }) : _moveEntryUseCase = moveEntryUseCase,
       _listDirectoryUseCase = listDirectoryUseCase,
       _createFolderUseCase = createFolderUseCase,
       _deleteFileUseCase = deleteFileUseCase,
       _batchDeleteUseCase = batchDeleteUseCase,
       _loadVisibleThumbnailsUseCase = loadVisibleThumbnailsUseCase,
       _getCachedThumbnailUseCase = getCachedThumbnailUseCase,
       _switchFileRootUseCase = switchFileRootUseCase,
       _isRootWritableUseCase = isRootWritableUseCase,
       super(const FileBrowserInitial());

  static const int _pageSize = 120;
  static const int _thumbnailBatchSize = 2;
  static const Duration _thumbnailRequestDebounce = Duration(milliseconds: 24);
  static const Duration _thumbnailBackoffBase = Duration(seconds: 2);
  static const Duration _thumbnailBackoffMax = Duration(seconds: 15);

  final ListDirectoryUseCase _listDirectoryUseCase;
  final CreateFolderUseCase _createFolderUseCase;
  final DeleteFileUseCase _deleteFileUseCase;
  final BatchDeleteUseCase _batchDeleteUseCase;
  final LoadVisibleThumbnailsUseCase _loadVisibleThumbnailsUseCase;
  final GetCachedThumbnailUseCase _getCachedThumbnailUseCase;
  final SwitchFileRootUseCase _switchFileRootUseCase;
  final IsRootWritableUseCase _isRootWritableUseCase;
  final MoveEntryUseCase? _moveEntryUseCase;

  String _currentRootId = 'fs';
  FileCategory _currentCategory = FileCategory.photo;
  bool _folderView = false;

  /// 当前排序字段：'modified'（默认） | 'size'
  String _currentSortBy = 'modified';

  /// 当前排序方向：'desc'（默认） | 'asc'
  String _currentSortOrder = 'desc';
  Timer? _thumbnailLoadTimer;
  Timer? _thumbnailBackoffTimer;
  StreamSubscription<int>? _thumbnailSubscription;
  bool _isLoadingThumbnails = false;
  int _thumbnailBackoffAttempt = 0;
  int _visibleStartIndex = 0;
  int _visibleEndIndex = 0;
  int _preloadStartIndex = 0;
  int _preloadEndIndex = 0;
  bool _allowThumbnailPreload = true;
  ScrollDirection _thumbnailScrollDirection = ScrollDirection.idle;
  final List<String> _priorityThumbnailPaths = [];

  String get currentRootId => _currentRootId;
  FileCategory get currentCategory => _currentCategory;
  bool get isFolderView => _folderView;
  bool get canMoveEntries => _moveEntryUseCase != null;
  String get currentSortBy => _currentSortBy;
  String get currentSortOrder => _currentSortOrder;

  Future<void> loadDirectory(NasPath path) async {
    final previousLoadedState = state is FileBrowserLoaded
        ? state as FileBrowserLoaded
        : null;
    _currentRootId = path.rootId;
    if (previousLoadedState == null) {
      emit(const FileBrowserLoading());
    }

    final result = await _loadPage(path: path);
    result.when(
      success: (page) {
        final samePath =
            previousLoadedState != null &&
            previousLoadedState.currentPath == path;
        if (samePath) {
          _emitRefreshedPage(
            path: path,
            page: page,
            previousState: previousLoadedState,
          );
        } else {
          _emitFreshPage(path: path, page: page);
        }
      },
      failure: (failure) {
        if (previousLoadedState != null) {
          _currentRootId = previousLoadedState.currentRootId;
          if (path.rootId != previousLoadedState.currentRootId) {
            unawaited(
              _switchFileRootUseCase.call(previousLoadedState.currentRootId),
            );
          }
          emit(previousLoadedState.copyWith(message: failure.message));
          // 切换根目录时缩略图缓存已被清空；回退到原来的列表后页面的
          // 可见范围没变，不会再次请求，这里主动补一次，避免只剩占位图标。
          _thumbnailBackoffAttempt = 0;
          _thumbnailLoadTimer?.cancel();
          _thumbnailLoadTimer = Timer(
            _thumbnailRequestDebounce,
            _loadNextBatch,
          );
          return;
        }
        emit(FileBrowserError(failure.message));
      },
    );
  }

  Future<void> loadRoot() async {
    await loadDirectory(NasPath.root(_currentRootId));
  }

  Future<AppResult<FileListPageEntity>> refreshDirectoryEntries(
    NasPath path,
  ) async {
    final previousLoadedState = state is FileBrowserLoaded
        ? state as FileBrowserLoaded
        : null;
    final result = await _loadPage(path: path);
    result.when(
      success: (page) {
        if (previousLoadedState != null &&
            previousLoadedState.currentPath == path) {
          _emitRefreshedPage(
            path: path,
            page: page,
            previousState: previousLoadedState,
          );
        } else {
          _emitFreshPage(path: path, page: page);
        }
      },
      failure: (_) {},
    );
    return result;
  }

  Future<void> switchRoot(String rootId) async {
    if (_currentRootId == rootId) {
      return;
    }

    final previousLoadedState = state is FileBrowserLoaded
        ? state as FileBrowserLoaded
        : null;
    final switchResult = await _switchFileRootUseCase.call(rootId);
    if (switchResult.isFailure) {
      if (previousLoadedState != null) {
        emit(
          previousLoadedState.copyWith(
            message: switchResult.failureOrNull!.message,
          ),
        );
        return;
      }
      emit(FileBrowserError(switchResult.failureOrNull!.message));
      return;
    }

    _currentRootId = rootId;
    _resetThumbnailCachesForDirectory();
    await loadRoot();
  }

  Future<void> switchCategory(FileCategory category) async {
    if (_currentCategory == category && !_folderView) {
      return;
    }
    final leavingFolderView = _folderView;
    _currentCategory = category;
    _folderView = false;
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      if (leavingFolderView) {
        _resetThumbnailWindow();
      }
      // 分类视图由服务端索引平铺列出全部文件（含子文件夹里的），始终从根目录查询
      await loadDirectory(NasPath.root(currentState.currentRootId));
    }
  }

  /// 切换到文件夹视图：从根目录开始逐级浏览。
  Future<void> switchToFolderView() async {
    if (_folderView) return;
    _folderView = true;
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      _resetThumbnailWindow();
      await loadDirectory(NasPath.root(currentState.currentRootId));
    }
  }

  Future<void> navigateTo(NasPath path) async {
    final currentState = state;
    if (currentState is FileBrowserLoaded && currentState.currentPath != path) {
      await loadDirectory(path);
    }
  }

  /// 切换排序方式并重新加载当前目录。
  /// sortBy: 'modified' | 'size'
  /// sortOrder: 'asc' | 'desc'
  Future<void> changeSort(String sortBy, String sortOrder) async {
    if (_currentSortBy == sortBy && _currentSortOrder == sortOrder) {
      return;
    }
    _currentSortBy = sortBy;
    _currentSortOrder = sortOrder;
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      _resetThumbnailCachesForDirectory();
      await loadDirectory(currentState.currentPath);
    }
  }

  List<FileEntryEntity> _filterFiles(List<FileEntryEntity> files) {
    if (_folderView) {
      return List<FileEntryEntity>.unmodifiable(files);
    }
    return files
        .where((file) {
          if (file.isDirectory) {
            return false;
          }
          final resolvedCategory = FileCategory.fromExtension(file.extension);
          return switch (_currentCategory) {
            FileCategory.other => resolvedCategory == null,
            _ => resolvedCategory == _currentCategory,
          };
        })
        .toList(growable: false);
  }

  Future<void> navigateToFolder(String folderName) async {
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      await loadDirectory(currentState.currentPath.append(folderName));
    }
  }

  Future<void> navigateUp() async {
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      await loadDirectory(currentState.currentPath.parent());
    }
  }

  /// 在当前目录新建文件夹；返回 null 表示成功，否则为错误提示。
  Future<String?> createFolder(String name) async {
    final currentState = state;
    if (currentState is! FileBrowserLoaded) return '页面尚未加载';
    final newPath = currentState.currentPath.append(name);
    final result = await _createFolderUseCase.call(newPath);
    if (result.isFailure) {
      return humanizeFolderError(result.failureOrNull!.message);
    }
    if (_folderView) {
      await refreshDirectoryEntries(currentState.currentPath);
    } else {
      _appendFolderLocally(currentState, name);
    }
    return null;
  }

  /// 重命名文件或文件夹；返回 null 表示成功，否则为错误提示。
  Future<String?> renameEntry(FileEntryEntity entry, String newName) async {
    final currentState = state;
    final moveEntry = _moveEntryUseCase;
    if (currentState is! FileBrowserLoaded) return '页面尚未加载';
    if (moveEntry == null) return '当前版本不支持重命名';
    final from = NasPath(rootId: currentState.currentRootId, path: entry.path);
    final to = from.parent().append(newName);
    if (from == to) return null;
    final result = await moveEntry.call(from, to);
    if (result.isFailure) {
      return humanizeFolderError(result.failureOrNull!.message);
    }
    _evictThumbnail(entry.path);
    await refreshDirectoryEntries(currentState.currentPath);
    return null;
  }

  /// 把多个文件/文件夹移动到 targetDirectory；返回给用户看的结果说明。
  Future<String> moveEntries(
    List<FileEntryEntity> entries,
    NasPath targetDirectory,
  ) async {
    final currentState = state;
    final moveEntry = _moveEntryUseCase;
    if (currentState is! FileBrowserLoaded || entries.isEmpty) return '';
    if (moveEntry == null) return '当前版本不支持移动';
    var moved = 0;
    String? firstError;
    for (final entry in entries) {
      final from = NasPath(
        rootId: currentState.currentRootId,
        path: entry.path,
      );
      final to = targetDirectory.append(entry.name);
      if (from == to) continue;
      if (entry.isDirectory &&
          (targetDirectory.path == entry.path ||
              targetDirectory.path.startsWith('${entry.path}/'))) {
        firstError ??= '不能把文件夹移动到它自己里面';
        continue;
      }
      final result = await moveEntry.call(from, to);
      if (result.isSuccess) {
        moved += 1;
        _evictThumbnail(entry.path);
      } else {
        firstError ??= humanizeFolderError(result.failureOrNull!.message);
      }
    }
    await refreshDirectoryEntries(currentState.currentPath);
    final target = targetDirectory.isRoot ? '根目录' : targetDirectory.fileName;
    if (firstError == null) return '已移动 $moved 项到“$target”';
    if (moved == 0) return '移动失败：$firstError';
    return '已移动 $moved 项，${entries.length - moved} 项失败：$firstError';
  }

  /// 列出某个目录下的子文件夹（给“移动到…”对话框用）。
  Future<List<FileEntryEntity>> listSubfolders(NasPath path) async {
    final result = await _listDirectoryUseCase.call(
      ListDirectoryParams(
        path: path,
        category: _currentCategory,
        limit: 1000,
        sortBy: 'name',
        sortOrder: 'asc',
        folderView: true,
      ),
    );
    return result.dataOrNull?.items
            .where((e) => e.isDirectory)
            .toList(growable: false) ??
        const <FileEntryEntity>[];
  }

  static String humanizeFolderError(String raw) {
    if (raw.contains('status code of 405') ||
        raw.contains('status code of 501')) {
      return '手机服务端版本太旧，不支持文件夹。请安装 1.1.0 或更高版本的服务端';
    }
    if (raw.contains('status code of 412') || raw.contains('already exists')) {
      return '已存在同名的文件或文件夹';
    }
    if (raw.contains('status code of 409')) {
      return '目标位置不存在或无效';
    }
    if (raw.contains('status code of 400')) {
      return '名称无效';
    }
    if (raw.contains('status code of 403')) {
      return '没有权限';
    }
    if (raw.contains('status code of 404')) {
      return '文件已不存在，请刷新';
    }
    return raw;
  }

  Future<void> deleteFile(String filePath) async {
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      final result = await _deleteFileUseCase.call(
        NasPath(rootId: currentState.currentRootId, path: filePath),
      );
      result.when(
        success: (_) => _removeEntriesLocally(currentState, {filePath}),
        failure: (failure) =>
            emit(currentState.copyWith(message: failure.message)),
      );
    }
  }

  void enterSelectionMode() {
    final currentState = state;
    if (currentState is FileBrowserLoaded && !currentState.selectionMode) {
      emit(currentState.copyWith(selectionMode: true));
    }
  }

  void enterSelectionModeAndToggle(String filePath) {
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      final newSelected = Set<String>.from(currentState.selectedPaths)
        ..add(filePath);
      emit(
        currentState.copyWith(selectionMode: true, selectedPaths: newSelected),
      );
    }
  }

  void toggleSelection(String filePath) {
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      final newSelected = Set<String>.from(currentState.selectedPaths);
      if (newSelected.contains(filePath)) {
        newSelected.remove(filePath);
      } else {
        newSelected.add(filePath);
      }
      if (newSelected.isEmpty) {
        emit(
          currentState.copyWith(
            selectionMode: false,
            selectedPaths: const <String>{},
          ),
        );
        return;
      }
      emit(
        currentState.copyWith(selectionMode: true, selectedPaths: newSelected),
      );
    }
  }

  /// 桌面端：用给定集合整体替换当前选择（单击、Ctrl/Shift 多选、框选、全选）。
  void setSelection(Set<String> paths) {
    final currentState = state;
    if (currentState is! FileBrowserLoaded) {
      return;
    }
    if (setEquals(currentState.selectedPaths, paths)) {
      return;
    }
    emit(
      currentState.copyWith(
        selectionMode: paths.isNotEmpty,
        selectedPaths: Set<String>.unmodifiable(paths),
      ),
    );
  }

  void exitSelectionMode() {
    final currentState = state;
    if (currentState is FileBrowserLoaded) {
      emit(
        currentState.copyWith(
          selectionMode: false,
          selectedPaths: const <String>{},
        ),
      );
    }
  }

  Future<void> batchDelete(List<NasPath> paths) async {
    final currentState = state;
    if (currentState is! FileBrowserLoaded || paths.isEmpty) {
      return;
    }

    final result = await _batchDeleteUseCase.call(paths);
    result.when(
      success: (results) async {
        final successCount = results.where((r) => r.success).length;
        final failedResults = results
            .where((r) => !r.success)
            .toList(growable: false);

        if (successCount > 0) {
          final deletedPaths = _resolveDeletedPaths(paths, results);
          _removeEntriesLocally(currentState, deletedPaths);
        }

        final message = _buildBatchDeleteMessage(
          successCount: successCount,
          failedResults: failedResults,
        );

        final nextState = state;
        if (nextState is FileBrowserLoaded) {
          emit(nextState.copyWith(message: message));
        }
      },
      failure: (failure) {
        emit(
          currentState.copyWith(
            message: '批量删除失败：${_humanizeDeleteError(failure.message)}',
          ),
        );
      },
    );
  }

  Future<void> loadMore() async {
    final currentState = state;
    if (currentState is! FileBrowserLoaded ||
        !currentState.hasMore ||
        currentState.isLoadingMore) {
      return;
    }

    emit(currentState.copyWith(isLoadingMore: true, message: null));
    final result = await _loadPage(
      path: currentState.currentPath,
      cursor: currentState.nextCursor,
    );
    result.when(
      success: (page) {
        final merged = List<FileEntryEntity>.from(currentState.allFiles);
        final seenPaths = merged.map((file) => file.path).toSet();
        for (final item in page.items) {
          if (seenPaths.add(item.path)) {
            merged.add(item);
          }
        }
        final filteredFiles = _filterFiles(merged);
        emit(
          currentState.copyWith(
            allFiles: merged,
            filteredFiles: filteredFiles,
            mediaFiles: _buildMediaFiles(filteredFiles),
            hasMore: page.hasMore,
            nextCursor: page.nextCursor,
            isLoadingMore: false,
          ),
        );
        _loadNextBatch();
      },
      failure: (failure) {
        emit(
          currentState.copyWith(isLoadingMore: false, message: failure.message),
        );
      },
    );
  }

  String _buildBatchDeleteMessage({
    required int successCount,
    required List<BatchDeleteResultEntity> failedResults,
  }) {
    final failedCount = failedResults.length;
    if (successCount == 0 && failedCount == 0) {
      return '没有可删除的文件';
    }
    if (failedCount == 0) {
      return '已删除 $successCount 项';
    }

    final firstError = _humanizeDeleteError(failedResults.first.error);
    if (successCount == 0) {
      return '删除失败：$firstError';
    }
    return '已删除 $successCount 项，失败 $failedCount 项';
  }

  String _humanizeDeleteError(String? rawError) {
    final error = rawError?.trim();
    if (error == null || error.isEmpty) {
      return '请稍后重试';
    }
    if (error.startsWith('NOT_FOUND:') ||
        error.contains('status code of 404') ||
        error.contains('Resource not found')) {
      return '资源不存在';
    }
    if (error.startsWith('INVALID_PATH:')) {
      return '路径无效';
    }
    if (error.startsWith('NOT_SUPPORTED:')) {
      return '当前服务端不支持此删除方式';
    }
    if (error.contains('status code of 401')) {
      return '认证已失效，请重新登录';
    }
    if (error.contains('status code of 403')) {
      return '无权删除该资源';
    }
    if (error.contains('Connection timeout')) {
      return '连接超时';
    }
    return error;
  }

  void requestThumbnailsForPaths(List<String> filePaths) {
    if (filePaths.isEmpty) {
      return;
    }

    for (final filePath in filePaths) {
      final fullPath = _buildRemoteResourcePath(filePath);
      if (_getCachedThumbnailUseCase.hasCached(fullPath) ||
          _getCachedThumbnailUseCase.shouldSkip(fullPath)) {
        continue;
      }
      if (!_priorityThumbnailPaths.contains(fullPath)) {
        _priorityThumbnailPaths.add(fullPath);
      }
    }

    if (!_isLoadingThumbnails) {
      _thumbnailLoadTimer?.cancel();
      _thumbnailLoadTimer = Timer(_thumbnailRequestDebounce, _loadNextBatch);
    }
  }

  bool canSkipDirectoryRefreshOnReconnect() {
    final currentState = state;
    if (currentState is! FileBrowserLoaded) {
      return false;
    }
    if (currentState.allFiles.isEmpty) {
      return false;
    }

    final mediaFiles = currentState.mediaFiles;
    if (mediaFiles.isEmpty) {
      return true;
    }

    final sampleSize = mediaFiles.length < 24 ? mediaFiles.length : 24;
    var needsThumbnail = 0;
    var cachedCount = 0;
    for (var index = 0; index < sampleSize; index++) {
      needsThumbnail++;
      if (hasThumbnail(mediaFiles[index].path)) {
        cachedCount++;
      }
    }
    return cachedCount >= (needsThumbnail * 0.75).ceil();
  }

  void requestThumbnails({
    required int visibleStartIndex,
    required int visibleEndIndex,
    required int preloadStartIndex,
    required int preloadEndIndex,
    bool allowPreload = true,
    ScrollDirection scrollDirection = ScrollDirection.idle,
  }) {
    final currentState = state;
    if (currentState is! FileBrowserLoaded) {
      return;
    }

    _visibleStartIndex = visibleStartIndex;
    _visibleEndIndex = visibleEndIndex;
    _preloadStartIndex = preloadStartIndex;
    _preloadEndIndex = preloadEndIndex;
    _allowThumbnailPreload = allowPreload;
    _thumbnailScrollDirection = scrollDirection;

    if (!_isLoadingThumbnails) {
      _thumbnailLoadTimer?.cancel();
      _thumbnailLoadTimer = Timer(_thumbnailRequestDebounce, _loadNextBatch);
    }
  }

  void _loadNextBatch() {
    if (_isLoadingThumbnails) {
      return;
    }

    final currentState = state;
    if (currentState is! FileBrowserLoaded) {
      return;
    }

    final mediaFiles = currentState.mediaFiles;

    if (mediaFiles.isEmpty) {
      return;
    }

    final pathsToLoad = _buildThumbnailLoadQueue(mediaFiles);

    if (pathsToLoad.isEmpty) {
      _thumbnailBackoffAttempt = 0;
      return;
    }

    final batchPaths = pathsToLoad
        .take(_thumbnailBatchSize)
        .toList(growable: false);
    _isLoadingThumbnails = true;
    _thumbnailSubscription?.cancel();
    _thumbnailBackoffTimer?.cancel();

    var cachedThisBatch = 0;
    _thumbnailSubscription = _loadVisibleThumbnailsUseCase
        .call(LoadVisibleThumbnailsParams(paths: batchPaths))
        .listen(
          (loadedCount) {
            cachedThisBatch += loadedCount;
          },
          onDone: () {
            _isLoadingThumbnails = false;
            if (cachedThisBatch > 0) {
              _thumbnailBackoffAttempt = 0;
              _loadNextBatch();
              return;
            }

            final remainingQueue = _buildThumbnailLoadQueue(mediaFiles);
            if (remainingQueue.isEmpty) {
              _thumbnailBackoffAttempt = 0;
              return;
            }

            _scheduleThumbnailBackoff();
          },
          onError: (_) {
            _isLoadingThumbnails = false;
            _scheduleThumbnailBackoff();
          },
        );
  }

  void _scheduleThumbnailBackoff() {
    _thumbnailBackoffTimer?.cancel();
    _thumbnailBackoffAttempt = (_thumbnailBackoffAttempt + 1).clamp(1, 4);
    final multiplier = 1 << (_thumbnailBackoffAttempt - 1);
    final delay = Duration(
      milliseconds: (_thumbnailBackoffBase.inMilliseconds * multiplier).clamp(
        _thumbnailBackoffBase.inMilliseconds,
        _thumbnailBackoffMax.inMilliseconds,
      ),
    );
    _thumbnailBackoffTimer = Timer(delay, _loadNextBatch);
  }

  void _resetThumbnailWindow() {
    _visibleStartIndex = 0;
    _visibleEndIndex = 0;
    _preloadStartIndex = 0;
    _preloadEndIndex = 0;
    _allowThumbnailPreload = true;
    _thumbnailScrollDirection = ScrollDirection.idle;
    _thumbnailBackoffAttempt = 0;
    _thumbnailBackoffTimer?.cancel();
  }

  void _resetThumbnailCachesForDirectory() {
    _getCachedThumbnailUseCase.clearCache();
    _getCachedThumbnailUseCase.clearFailedPaths();
    _thumbnailBackoffAttempt = 0;
    _thumbnailBackoffTimer?.cancel();
  }

  String _buildRemoteResourcePath(String filePath) {
    return '/$_currentRootId$filePath';
  }

  Uint8List? getThumbnail(String filePath) {
    return _getCachedThumbnailUseCase.call(_buildRemoteResourcePath(filePath));
  }

  Stream<void> watchThumbnail(String filePath) {
    final fullPath = _buildRemoteResourcePath(filePath);
    return _getCachedThumbnailUseCase.thumbnailUpdates
        .where((path) => path == fullPath)
        .map((_) {});
  }

  bool hasThumbnail(String filePath) {
    return _getCachedThumbnailUseCase.hasCached(
      _buildRemoteResourcePath(filePath),
    );
  }

  void clearThumbnailCache() {
    _getCachedThumbnailUseCase.clearCache();
  }

  void clearThumbnailFailures() {
    _getCachedThumbnailUseCase.clearFailedPaths();
  }

  void clearDirectoryCache() {}

  void clearAllCache() {
    clearThumbnailCache();
    clearDirectoryCache();
  }

  @override
  Future<void> close() {
    _thumbnailLoadTimer?.cancel();
    _thumbnailBackoffTimer?.cancel();
    _thumbnailSubscription?.cancel();
    return super.close();
  }

  Future<AppResult<FileListPageEntity>> _loadPage({
    required NasPath path,
    String? cursor,
  }) {
    return _listDirectoryUseCase.call(
      ListDirectoryParams(
        path: path,
        category: _currentCategory,
        cursor: cursor,
        limit: _pageSize,
        sortBy: _currentSortBy,
        sortOrder: _currentSortOrder,
        folderView: _folderView,
      ),
    );
  }

  void _emitFreshPage({
    required NasPath path,
    required FileListPageEntity page,
  }) {
    _resetThumbnailWindow();
    final files = _filterFiles(page.items);
    final mediaFiles = _buildMediaFiles(files);
    emit(
      FileBrowserLoaded(
        allFiles: page.items,
        filteredFiles: files,
        mediaFiles: mediaFiles,
        currentPath: path,
        currentRootId: _currentRootId,
        currentRootWritable: _isRootWritableUseCase.call(_currentRootId),
        currentCategory: _currentCategory,
        selectionMode: false,
        selectedPaths: const <String>{},
        hasMore: page.hasMore,
        nextCursor: page.nextCursor,
        isLoadingMore: false,
        message: null,
        sortBy: _currentSortBy,
        sortOrder: _currentSortOrder,
        folderView: _folderView,
      ),
    );
    _loadNextBatch();
  }

  void _emitRefreshedPage({
    required NasPath path,
    required FileListPageEntity page,
    required FileBrowserLoaded previousState,
  }) {
    if (previousState.currentCategory != _currentCategory ||
        previousState.folderView != _folderView) {
      _resetThumbnailWindow();
    }

    final oldPaths = previousState.allFiles.map((file) => file.path).toSet();
    final newItems = page.items;
    final newPaths = newItems.map((file) => file.path).toSet();

    for (final removedPath in oldPaths.difference(newPaths)) {
      _evictThumbnail(removedPath);
    }

    final addedPaths = newPaths.difference(oldPaths);
    final files = _filterFiles(newItems);
    final mediaFiles = _buildMediaFiles(files);

    emit(
      previousState.copyWith(
        allFiles: newItems,
        filteredFiles: files,
        mediaFiles: mediaFiles,
        currentPath: path,
        currentRootId: _currentRootId,
        currentRootWritable: _isRootWritableUseCase.call(_currentRootId),
        currentCategory: _currentCategory,
        hasMore: page.hasMore,
        nextCursor: page.nextCursor,
        isLoadingMore: false,
        message: null,
        sortBy: _currentSortBy,
        sortOrder: _currentSortOrder,
        folderView: _folderView,
      ),
    );

    final newMediaPaths = mediaFiles
        .where((file) => addedPaths.contains(file.path))
        .map((file) => file.path)
        .toList(growable: false);
    if (newMediaPaths.isNotEmpty) {
      requestThumbnailsForPaths(newMediaPaths);
    } else {
      _loadNextBatch();
    }
  }

  void _appendFolderLocally(FileBrowserLoaded state, String name) {
    final folderPath = state.currentPath.append(name).path;
    if (state.allFiles.any((file) => file.path == folderPath)) {
      return;
    }

    final entry = FileEntryEntity(
      name: name,
      path: folderPath,
      type: FileType.directory,
      size: 0,
      modifiedAt: DateTime.now(),
    );
    final allFiles = List<FileEntryEntity>.from(state.allFiles)..add(entry);
    final filteredFiles = _filterFiles(allFiles);
    emit(
      state.copyWith(
        allFiles: allFiles,
        filteredFiles: filteredFiles,
        mediaFiles: _buildMediaFiles(filteredFiles),
      ),
    );
  }

  void _removeEntriesLocally(FileBrowserLoaded state, Set<String> filePaths) {
    if (filePaths.isEmpty) {
      return;
    }

    for (final filePath in filePaths) {
      _evictThumbnail(filePath);
    }

    final allFiles = state.allFiles
        .where((file) => !filePaths.contains(file.path))
        .toList(growable: false);
    final filteredFiles = _filterFiles(allFiles);
    final selectedPaths = Set<String>.from(state.selectedPaths)
      ..removeWhere(filePaths.contains);
    emit(
      state.copyWith(
        allFiles: allFiles,
        filteredFiles: filteredFiles,
        mediaFiles: _buildMediaFiles(filteredFiles),
        selectedPaths: selectedPaths,
        selectionMode: selectedPaths.isNotEmpty && state.selectionMode,
      ),
    );
  }

  Set<String> _resolveDeletedPaths(
    List<NasPath> requestedPaths,
    List<BatchDeleteResultEntity> results,
  ) {
    final deletedPaths = <String>{};
    for (final result in results.where((item) => item.success)) {
      final matchedPath = requestedPaths
          .map((path) => path.path)
          .firstWhere(
            (path) => path == result.path || result.path.endsWith(path),
            orElse: () => '',
          );
      if (matchedPath.isNotEmpty) {
        deletedPaths.add(matchedPath);
      }
    }
    return deletedPaths;
  }

  void _evictThumbnail(String filePath) {
    _getCachedThumbnailUseCase.evictThumbnail(
      _buildRemoteResourcePath(filePath),
    );
  }

  List<FileEntryEntity> _buildMediaFiles(List<FileEntryEntity> files) {
    return files
        .where((file) => file.isFile && (file.isImage || file.isVideo))
        .toList(growable: false);
  }

  List<String> _buildThumbnailLoadQueue(List<FileEntryEntity> mediaFiles) {
    final visibleStart = _visibleStartIndex.clamp(0, mediaFiles.length);
    final visibleEnd = _visibleEndIndex.clamp(0, mediaFiles.length);
    final preloadStart = _preloadStartIndex.clamp(0, mediaFiles.length);
    final preloadEnd = _preloadEndIndex.clamp(0, mediaFiles.length);
    final queue = <String>[];
    final seen = <String>{};

    for (final fullPath in _priorityThumbnailPaths) {
      if (_getCachedThumbnailUseCase.hasCached(fullPath) ||
          _getCachedThumbnailUseCase.shouldSkip(fullPath) ||
          !seen.add(fullPath)) {
        continue;
      }
      queue.add(fullPath);
    }

    void addRange(int start, int end) {
      for (var index = start; index < end; index++) {
        final fullPath = _buildRemoteResourcePath(mediaFiles[index].path);
        if (_getCachedThumbnailUseCase.hasCached(fullPath) ||
            _getCachedThumbnailUseCase.shouldSkip(fullPath) ||
            !seen.add(fullPath)) {
          continue;
        }
        queue.add(fullPath);
      }
    }

    addRange(visibleStart, visibleEnd);

    if (!_allowThumbnailPreload) {
      _prunePriorityThumbnailPaths();
      return queue;
    }

    final loadBelowFirst =
        _thumbnailScrollDirection == ScrollDirection.idle ||
        _thumbnailScrollDirection == ScrollDirection.forward;
    if (loadBelowFirst) {
      addRange(visibleEnd, preloadEnd);
      addRange(preloadStart, visibleStart);
    } else {
      addRange(preloadStart, visibleStart);
      addRange(visibleEnd, preloadEnd);
    }

    _prunePriorityThumbnailPaths();
    return queue;
  }

  void _prunePriorityThumbnailPaths() {
    _priorityThumbnailPaths.removeWhere(
      (path) =>
          _getCachedThumbnailUseCase.hasCached(path) ||
          _getCachedThumbnailUseCase.shouldSkip(path),
    );
  }
}
