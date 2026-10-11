/// 文件输入：FileBrowserCubit、TransferCubit 状态
/// 文件职责：Windows 桌面端文件浏览页（按资源管理器的操作习惯设计）
///   - 顶部：标题、搜索、上传；命令栏：分类、共享/原机、选择操作、排序、视图切换、刷新
///   - 内容：自适应网格（Ctrl+滚轮缩放）或详细信息列表
///   - 鼠标：单击选中、Ctrl/Shift 多选、框选、双击打开、右键菜单
///   - 键盘：Ctrl+A、Delete、Enter、Esc、F5、Ctrl+F、Ctrl+U、方向键
///   - 从资源管理器拖入文件即可上传；底部状态栏显示项目数、选中数和传输状态
/// 文件对外接口：FileBrowserPage
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/desktop/desktop_ui.dart';
import '../../../../core/path/nas_path.dart';
import '../../../preview/presentation/pages/gallery_page.dart';
import '../../../transfer/domain/entities/transfer_direction.dart';
import '../../../transfer/domain/entities/transfer_status.dart';
import '../../../transfer/domain/entities/transfer_task_entity.dart';
import '../../../transfer/presentation/cubit/transfer_cubit.dart';
import '../../../transfer/presentation/cubit/transfer_state.dart';
import '../../../transfer/presentation/utils/queue_upload_to_server_directory.dart';
import '../../../transfer/presentation/widgets/desktop_transfer_panel.dart';
import '../../../transfer/presentation/widgets/upload_conflict_dialog.dart';
import '../../domain/entities/file_category.dart';
import '../../domain/entities/file_entry_entity.dart';
import '../cubit/file_browser_cubit.dart';
import '../cubit/file_browser_state.dart';
import '../utils/desktop_file_downloader.dart';
import '../widgets/desktop_file_widgets.dart';

enum _ViewMode { grid, list }

class FileBrowserPage extends StatefulWidget {
  /// 兼容旧调用；桌面端不再需要为底部导航栏预留空间。
  final double bottomPadding;

  const FileBrowserPage({super.key, this.bottomPadding = 0});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  static const _queueUploadToServerDirectory = QueueUploadToServerDirectory();
  static const String _folderSegment = 'folders';
  static const String _prefViewMode = 'desktop_file_view_mode';
  static const String _prefTileExtent = 'desktop_file_tile_extent';
  static const double _minTileExtent = 110;
  static const double _maxTileExtent = 320;
  static const double _gridSpacing = 8;
  static const double _contentPadding = 16;
  static const double _listTopPadding = 4;
  static const int _preloadRows = 2;
  static const Duration _scrollSettleDelay = Duration(milliseconds: 72);
  static const Duration _doubleClickTimeout = Duration(milliseconds: 450);

  final ScrollController _scrollController = ScrollController();
  final FocusNode _pageFocusNode = FocusNode(debugLabel: 'file-browser');
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'file-search');
  final TextEditingController _searchController = TextEditingController();

  _ViewMode _viewMode = _ViewMode.grid;
  double _tileExtent = 170;
  String _searchQuery = '';

  // 布局（用于缩略图可见范围、框选、方向键滚动）
  int _columns = 1;
  double _tileWidth = 170;
  double _tileHeight = 210;
  double _viewportWidth = 0;

  // 鼠标交互
  bool _itemPointerHandled = false;
  String? _anchorPath;
  String? _lastClickPath;
  DateTime? _lastClickAt;
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;
  Set<String> _marqueeBase = const <String>{};
  bool _ctrlPressed = false;
  bool _dropHovering = false;

  // 滚动与缩略图
  double _lastScrollOffset = 0;
  bool _isScrollActive = false;
  bool _lastPreloadEnabled = true;
  Timer? _scrollSettleTimer;
  int _lastVisibleStartIndex = -1;
  int _lastVisibleEndIndex = -1;
  int _lastFocusedStartIndex = -1;
  int _lastFocusedEndIndex = -1;
  NasPath? _lastThumbnailNavigationPath;
  String? _lastThumbnailRootId;
  FileCategory? _lastThumbnailCategory;

  // 上传跟踪
  final Map<String, _TrackedUploadTask> _trackedUploadTasks = {};
  int _completedTrackedUploadCount = 0;
  int _skippedTrackedUploadCount = 0;
  int _failedTrackedUploadCount = 0;
  String? _activeConflictTaskId;
  bool _uploadRefreshPending = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    unawaited(_restoreViewPreferences());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _scrollController.removeListener(_onScroll);
    _scrollSettleTimer?.cancel();
    _scrollController.dispose();
    _pageFocusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 偏好设置
  // ---------------------------------------------------------------------------

  Future<void> _restoreViewPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mode = prefs.getString(_prefViewMode);
      final extent = prefs.getDouble(_prefTileExtent);
      if (!mounted) return;
      setState(() {
        _viewMode = mode == 'list' ? _ViewMode.list : _ViewMode.grid;
        if (extent != null) {
          _tileExtent = extent.clamp(_minTileExtent, _maxTileExtent);
        }
      });
    } catch (_) {}
  }

  Future<void> _saveViewPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefViewMode,
        _viewMode == _ViewMode.list ? 'list' : 'grid',
      );
      await prefs.setDouble(_prefTileExtent, _tileExtent);
    } catch (_) {}
  }

  void _setViewMode(_ViewMode mode) {
    if (_viewMode == mode) return;
    setState(() => _viewMode = mode);
    _resetVisibleRangeTracking();
    _scheduleVisibleThumbnailRequest();
    unawaited(_saveViewPreferences());
  }

  void _setTileExtent(double value, {bool save = true}) {
    final next = value.clamp(_minTileExtent, _maxTileExtent).toDouble();
    if ((next - _tileExtent).abs() < 0.5) return;
    setState(() => _tileExtent = next);
    _resetVisibleRangeTracking();
    _scheduleVisibleThumbnailRequest();
    if (save) unawaited(_saveViewPreferences());
  }

  bool _onHardwareKey(KeyEvent event) {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrlPressed && mounted) {
      setState(() => _ctrlPressed = ctrl);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 数据辅助
  // ---------------------------------------------------------------------------

  List<FileEntryEntity> _displayedFiles(FileBrowserLoaded state) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return state.filteredFiles;
    }
    return state.filteredFiles
        .where((file) => file.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  FileBrowserLoaded? get _loadedState {
    final state = context.read<FileBrowserCubit>().state;
    return state is FileBrowserLoaded ? state : null;
  }

  bool _isMobileServer() {
    try {
      final platform = ServiceLocator().currentSession.serverPlatform;
      return platform == 'android' || platform == 'ios';
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 布局计算
  // ---------------------------------------------------------------------------

  void _updateLayout(double width) {
    _viewportWidth = width;
    final usable = math.max(0.0, width - _contentPadding * 2);
    final columns = math.max(
      1,
      ((usable + _gridSpacing) / (_tileExtent + _gridSpacing)).floor(),
    );
    _columns = columns;
    _tileWidth = (usable - _gridSpacing * (columns - 1)) / columns;
    _tileHeight = _tileWidth + DesktopFileGridTile.nameAreaHeight - 12;
  }

  double get _rowStride => _viewMode == _ViewMode.grid
      ? _tileHeight + _gridSpacing
      : DesktopListColumns.rowHeight;

  double get _contentTop =>
      _viewMode == _ViewMode.grid ? _contentPadding : _listTopPadding;

  int get _itemsPerRow => _viewMode == _ViewMode.grid ? _columns : 1;

  Rect _itemRect(int index) {
    if (_viewMode == _ViewMode.list) {
      final top = _listTopPadding + index * DesktopListColumns.rowHeight;
      return Rect.fromLTWH(
        _contentPadding,
        top,
        math.max(0, _viewportWidth - _contentPadding * 2),
        DesktopListColumns.rowHeight,
      );
    }
    final row = index ~/ _columns;
    final col = index % _columns;
    return Rect.fromLTWH(
      _contentPadding + col * (_tileWidth + _gridSpacing),
      _contentPadding + row * (_tileHeight + _gridSpacing),
      _tileWidth,
      _tileHeight,
    );
  }

  // ---------------------------------------------------------------------------
  // 滚动、分页加载与缩略图
  // ---------------------------------------------------------------------------

  void _onScroll() {
    _syncVisibleThumbnailRange();
    _maybeLoadMore();
    if (_scrollController.hasClients) {
      _lastScrollOffset = _scrollController.offset;
    }
  }

  void _resetVisibleRangeTracking() {
    _lastVisibleStartIndex = -1;
    _lastVisibleEndIndex = -1;
    _lastFocusedStartIndex = -1;
    _lastFocusedEndIndex = -1;
    _lastPreloadEnabled = true;
  }

  void _scheduleVisibleThumbnailRequest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncVisibleThumbnailRange();
      _maybeLoadMore(force: true);
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      _markScrollActive();
      return false;
    }
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.idle) {
        _scheduleSettledScrollWork();
      } else {
        _markScrollActive();
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      _scheduleSettledScrollWork();
    }
    return false;
  }

  void _markScrollActive() {
    _scrollSettleTimer?.cancel();
    if (_isScrollActive) return;
    _isScrollActive = true;
  }

  void _scheduleSettledScrollWork() {
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = Timer(_scrollSettleDelay, () {
      if (!mounted) return;
      _isScrollActive = false;
      _syncVisibleThumbnailRange();
      _maybeLoadMore(force: true);
    });
  }

  void _maybeLoadMore({bool force = false}) {
    if (!_scrollController.hasClients) return;
    final shouldLoadMore = _scrollController.position.extentAfter < 800;
    if (!shouldLoadMore) {
      return;
    }
    if (_isScrollActive && !force) {
      return;
    }
    context.read<FileBrowserCubit>().loadMore();
  }

  void _syncVisibleThumbnailRange() {
    final cubit = context.read<FileBrowserCubit>();
    final state = cubit.state;
    if (state is! FileBrowserLoaded) return;
    if (!_scrollController.hasClients) return;
    final viewportHeight = _scrollController.position.viewportDimension;
    if (viewportHeight <= 0) return;

    final scrollOffset = _scrollController.offset;
    final stride = _rowStride;
    final perRow = _itemsPerRow;
    final firstVisibleRow = math.max(
      0,
      ((scrollOffset - _contentTop) / stride).floor(),
    );
    final lastVisibleRow = math.max(
      0,
      ((scrollOffset + viewportHeight - _contentTop) / stride).floor(),
    );

    if (_searchQuery.trim().isNotEmpty) {
      final displayed = _displayedFiles(state);
      final start = (firstVisibleRow * perRow).clamp(0, displayed.length);
      final end = ((lastVisibleRow + 1 + _preloadRows) * perRow).clamp(
        0,
        displayed.length,
      );
      cubit.requestThumbnailsForPaths(
        displayed
            .sublist(start, end)
            .where((f) => f.isImage || f.isVideo)
            .map((f) => f.path)
            .toList(growable: false),
      );
      return;
    }

    final mediaFiles = state.mediaFiles;
    if (mediaFiles.isEmpty) return;
    final visibleStartIndex = (firstVisibleRow * perRow).clamp(
      0,
      mediaFiles.length,
    );
    final visibleEndIndex = ((lastVisibleRow + 1) * perRow).clamp(
      0,
      mediaFiles.length,
    );
    final startIndex = ((firstVisibleRow - _preloadRows) * perRow).clamp(
      0,
      mediaFiles.length,
    );
    final endIndex = ((lastVisibleRow + _preloadRows + 1) * perRow).clamp(
      0,
      mediaFiles.length,
    );

    if (startIndex == _lastVisibleStartIndex &&
        endIndex == _lastVisibleEndIndex &&
        visibleStartIndex == _lastFocusedStartIndex &&
        visibleEndIndex == _lastFocusedEndIndex &&
        _lastPreloadEnabled == !_isScrollActive) {
      return;
    }
    _lastVisibleStartIndex = startIndex;
    _lastVisibleEndIndex = endIndex;
    _lastFocusedStartIndex = visibleStartIndex;
    _lastFocusedEndIndex = visibleEndIndex;
    _lastPreloadEnabled = !_isScrollActive;

    cubit.requestThumbnails(
      visibleStartIndex: visibleStartIndex,
      visibleEndIndex: visibleEndIndex,
      preloadStartIndex: startIndex,
      preloadEndIndex: endIndex,
      allowPreload: !_isScrollActive,
      scrollDirection: _resolveScrollDirection(scrollOffset),
    );
  }

  ScrollDirection _resolveScrollDirection(double currentOffset) {
    if (currentOffset > _lastScrollOffset) return ScrollDirection.forward;
    if (currentOffset < _lastScrollOffset) return ScrollDirection.reverse;
    return ScrollDirection.idle;
  }

  Future<void> _refresh() async {
    final cubit = context.read<FileBrowserCubit>();
    final state = cubit.state;
    if (state is FileBrowserLoaded) {
      await cubit.refreshDirectoryEntries(state.currentPath);
      return;
    }
    await cubit.loadRoot();
  }

  void _ensureVisible(int index) {
    if (!_scrollController.hasClients) return;
    final rect = _itemRect(index);
    final position = _scrollController.position;
    final top = position.pixels;
    final bottom = top + position.viewportDimension;
    double? target;
    if (rect.top < top) {
      target = rect.top - _contentTop;
    } else if (rect.bottom > bottom) {
      target = rect.bottom - position.viewportDimension + _contentTop;
    }
    if (target != null) {
      _scrollController.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 选择
  // ---------------------------------------------------------------------------

  void _setSelection(Set<String> paths) {
    context.read<FileBrowserCubit>().setSelection(paths);
  }

  void _selectAll() {
    final state = _loadedState;
    if (state == null) return;
    _setSelection(_displayedFiles(state).map((f) => f.path).toSet());
  }

  void _clearSelection() {
    _setSelection(const <String>{});
  }

  List<FileEntryEntity> _selectedFiles(FileBrowserLoaded state) {
    if (state.selectedPaths.isEmpty) return const <FileEntryEntity>[];
    return state.filteredFiles
        .where((f) => state.selectedPaths.contains(f.path))
        .toList(growable: false);
  }

  void _onItemPointerDown(
    PointerDownEvent event,
    FileEntryEntity file,
    int index,
  ) {
    _itemPointerHandled = true;
    if (!_searchFocusNode.hasFocus) {
      _pageFocusNode.requestFocus();
    } else {
      _searchFocusNode.unfocus();
      _pageFocusNode.requestFocus();
    }
    final state = _loadedState;
    if (state == null) return;

    if (event.buttons & kSecondaryMouseButton != 0) {
      if (!state.selectedPaths.contains(file.path)) {
        _setSelection({file.path});
        _anchorPath = file.path;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showItemContextMenu(event.position);
      });
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0) return;

    final now = DateTime.now();
    final isDoubleClick =
        _lastClickPath == file.path &&
        _lastClickAt != null &&
        now.difference(_lastClickAt!) < _doubleClickTimeout;
    _lastClickPath = isDoubleClick ? null : file.path;
    _lastClickAt = isDoubleClick ? null : now;

    final keyboard = HardwareKeyboard.instance;
    final displayed = _displayedFiles(state);
    if (keyboard.isShiftPressed && _anchorPath != null) {
      final anchorIndex = displayed.indexWhere((f) => f.path == _anchorPath);
      if (anchorIndex != -1) {
        final lo = math.min(anchorIndex, index);
        final hi = math.max(anchorIndex, index);
        final range = displayed.sublist(lo, hi + 1).map((f) => f.path);
        _setSelection(
          keyboard.isControlPressed
              ? {...state.selectedPaths, ...range}
              : range.toSet(),
        );
        return;
      }
    }
    if (keyboard.isControlPressed) {
      final next = Set<String>.from(state.selectedPaths);
      if (!next.remove(file.path)) next.add(file.path);
      _setSelection(next);
      _anchorPath = file.path;
      return;
    }

    _anchorPath = file.path;
    _setSelection({file.path});
    if (isDoubleClick) {
      _openFile(file);
    }
  }

  void _onBackgroundPointerDown(PointerDownEvent event) {
    if (_itemPointerHandled) {
      _itemPointerHandled = false;
      return;
    }
    if (_searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
    }
    _pageFocusNode.requestFocus();
    final state = _loadedState;
    if (state == null) return;

    if (event.buttons & kSecondaryMouseButton != 0) {
      _clearSelection();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showBackgroundContextMenu(event.position);
      });
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0) return;
    // 点在右侧滚动条上时交给滚动条处理，不开始框选
    if (event.localPosition.dx > _viewportWidth - 14) return;

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    _marqueeBase = ctrl ? Set<String>.from(state.selectedPaths) : <String>{};
    if (!ctrl) _clearSelection();
    final scroll = _scrollController.hasClients ? _scrollController.offset : 0;
    final start = event.localPosition + Offset(0, scroll.toDouble());
    setState(() {
      _marqueeStart = start;
      _marqueeCurrent = start;
    });
  }

  void _onBackgroundPointerMove(PointerMoveEvent event) {
    if (_marqueeStart == null) return;
    final state = _loadedState;
    if (state == null) return;
    final scroll = _scrollController.hasClients ? _scrollController.offset : 0;
    final current = event.localPosition + Offset(0, scroll.toDouble());
    setState(() => _marqueeCurrent = current);

    final rect = Rect.fromPoints(_marqueeStart!, current);
    final displayed = _displayedFiles(state);
    final hits = <String>{..._marqueeBase};
    // 只检查与选框垂直范围相交的行，避免遍历全部项目
    final stride = _rowStride;
    final perRow = _itemsPerRow;
    final firstRow = math.max(0, ((rect.top - _contentTop) / stride).floor());
    final lastRow = math.max(0, ((rect.bottom - _contentTop) / stride).floor());
    final startIndex = (firstRow * perRow).clamp(0, displayed.length);
    final endIndex = ((lastRow + 1) * perRow).clamp(0, displayed.length);
    for (var i = startIndex; i < endIndex; i++) {
      if (_itemRect(i).overlaps(rect)) {
        hits.add(displayed[i].path);
      }
    }
    if (!setEquals(hits, state.selectedPaths)) {
      _setSelection(hits);
    }
  }

  void _onBackgroundPointerUp(PointerEvent event) {
    _itemPointerHandled = false;
    if (_marqueeStart != null) {
      setState(() {
        _marqueeStart = null;
        _marqueeCurrent = null;
      });
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        _viewMode == _ViewMode.grid) {
      final delta = event.scrollDelta.dy;
      _setTileExtent(_tileExtent - delta * 0.25);
    }
  }

  // ---------------------------------------------------------------------------
  // 键盘
  // ---------------------------------------------------------------------------

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;

    if (_searchFocusNode.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        _searchController.clear();
        _onSearchChanged('');
        _searchFocusNode.unfocus();
        _pageFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _searchFocusNode.unfocus();
        _pageFocusNode.requestFocus();
        _moveSelection(0, select: true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final state = _loadedState;
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      _searchFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyU) {
      final cubit = context.read<FileBrowserCubit>();
      unawaited(_pickAndUploadFiles(context, cubit));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5 ||
        (ctrl && key == LogicalKeyboardKey.keyR)) {
      unawaited(_refresh());
      return KeyEventResult.handled;
    }
    if (state == null) return KeyEventResult.ignored;

    if (ctrl && key == LogicalKeyboardKey.keyA) {
      _selectAll();
      return KeyEventResult.handled;
    }
    if (state.folderView) {
      final cubit = context.read<FileBrowserCubit>();
      final alt = keyboard.isAltPressed;
      if (ctrl && keyboard.isShiftPressed && key == LogicalKeyboardKey.keyN) {
        unawaited(_createFolder());
        return KeyEventResult.handled;
      }
      if (!state.currentPath.isRoot &&
          (key == LogicalKeyboardKey.backspace ||
              (alt &&
                  (key == LogicalKeyboardKey.arrowUp ||
                      key == LogicalKeyboardKey.arrowLeft)))) {
        unawaited(cubit.navigateUp());
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.f2) {
      final selected = _selectedFiles(state);
      if (selected.length == 1) unawaited(_renameEntry(selected.first));
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.numpadAdd)) {
      _setTileExtent(_tileExtent + 20);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      _setTileExtent(_tileExtent - 20);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _clearSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      unawaited(_confirmDelete(_selectedFiles(state)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final selected = _selectedFiles(state);
      if (selected.length == 1) {
        _openFile(selected.first);
      } else if (selected.length > 1) {
        unawaited(_downloadFiles(selected));
      }
      return KeyEventResult.handled;
    }
    final perRow = _itemsPerRow;
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveSelection(1, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveSelection(-1, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(perRow, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-perRow, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _moveSelection(-1 << 30, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _moveSelection(1 << 30, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 方向键移动焦点项；extend 时与 Shift 一样扩展选区。
  void _moveSelection(int delta, {bool extend = false, bool select = false}) {
    final state = _loadedState;
    if (state == null) return;
    final displayed = _displayedFiles(state);
    if (displayed.isEmpty) return;
    var current = displayed.indexWhere((f) => f.path == _lastFocusedPath);
    if (current == -1) {
      current = displayed.indexWhere(
        (f) => state.selectedPaths.contains(f.path),
      );
    }
    final int next;
    if (current == -1 || select) {
      next = 0;
    } else {
      next = (current + delta).clamp(0, displayed.length - 1);
    }
    final target = displayed[next];
    _lastFocusedPath = target.path;
    if (extend && _anchorPath != null) {
      final anchorIndex = displayed.indexWhere((f) => f.path == _anchorPath);
      if (anchorIndex != -1) {
        final lo = math.min(anchorIndex, next);
        final hi = math.max(anchorIndex, next);
        _setSelection(displayed.sublist(lo, hi + 1).map((f) => f.path).toSet());
        _ensureVisible(next);
        return;
      }
    }
    _anchorPath = target.path;
    _setSelection({target.path});
    _ensureVisible(next);
  }

  String? _lastFocusedPath;

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);
    _clearSelection();
    _resetVisibleRangeTracking();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _scheduleVisibleThumbnailRequest();
  }

  // ---------------------------------------------------------------------------
  // 打开 / 下载 / 删除 / 属性
  // ---------------------------------------------------------------------------

  void _openFile(FileEntryEntity file) {
    final state = _loadedState;
    if (state == null) return;
    if (file.isDirectory) {
      context.read<FileBrowserCubit>().navigateToFolder(file.name);
      return;
    }
    if (file.isImage || file.isVideo) {
      _showPreviewDialog(context, file, state);
      return;
    }
    unawaited(
      DesktopFileDownloader.download(
        context,
        files: [file],
        rootId: state.currentRootId,
        openWhenDone: true,
      ),
    );
  }

  Future<void> _downloadFiles(
    List<FileEntryEntity> files, {
    bool chooseFolder = false,
  }) async {
    final state = _loadedState;
    if (state == null || files.isEmpty) return;
    final folderCount = files.where((f) => f.isDirectory).length;
    if (folderCount > 0) {
      files = files.where((f) => !f.isDirectory).toList(growable: false);
      _showSnack(
        files.isEmpty ? '暂不支持下载整个文件夹' : '暂不支持下载文件夹，已跳过 $folderCount 个文件夹',
      );
      if (files.isEmpty) return;
    }
    String? directory;
    if (chooseFolder) {
      directory = await getDirectoryPath(confirmButtonText: '下载到此文件夹');
      if (directory == null || !mounted) return;
    }
    await DesktopFileDownloader.download(
      context,
      files: files,
      rootId: state.currentRootId,
      targetDirectory: directory,
    );
  }

  Future<void> _confirmDelete(List<FileEntryEntity> files) async {
    final state = _loadedState;
    if (state == null || files.isEmpty) return;
    if (!state.currentRootWritable) {
      _showSnack('当前位置不允许删除文件');
      return;
    }
    final cubit = context.read<FileBrowserCubit>();
    final hasFolder = files.any((f) => f.isDirectory);
    final message = files.length == 1
        ? '确定要删除“${files.first.name}”吗？'
        : '确定要删除这 ${files.length} 项吗？';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(hasFolder ? '删除' : '删除文件'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            hasFolder
                ? '$message\n文件夹里的所有内容都会一起删除，且无法恢复。'
                : '$message\n删除后无法恢复。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: DesktopTokens.danger,
              foregroundColor: Colors.white,
              minimumSize: const Size(88, 40),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final paths = files
        .map((f) => NasPath(rootId: state.currentRootId, path: f.path))
        .toList(growable: false);
    await cubit.batchDelete(paths);
  }

  void _showProperties(FileEntryEntity file) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  label,
                  style: const TextStyle(color: DesktopTokens.textSecondary),
                ),
              ),
              Expanded(child: SelectableText(value)),
            ],
          ),
        );
        return AlertDialog(
          title: Row(
            children: [
              Icon(fileIconFor(file), color: fileIconColor(file)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row('类型', fileTypeLabel(file)),
                row('位置', file.path),
                row('大小', '${file.formattedSize}（${file.size} 字节）'),
                row('修改日期', formatDateTime(file.modifiedAt)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 文件夹：新建 / 重命名 / 移动 / 上传整个文件夹
  // ---------------------------------------------------------------------------

  static final RegExp _invalidNameChars = RegExp(r'[\\/:*?"<>|]');

  String? _validateName(String name, {String? original}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '名称不能为空';
    if (trimmed == '.' || trimmed == '..') return '名称无效';
    if (_invalidNameChars.hasMatch(trimmed)) {
      return r'名称不能包含 \ / : * ? " < > |';
    }
    if (trimmed.startsWith('.')) return '名称不能以 . 开头';
    final state = _loadedState;
    if (state != null &&
        trimmed != original &&
        state.allFiles.any(
          (f) => f.name.toLowerCase() == trimmed.toLowerCase(),
        )) {
      return '已存在同名的文件或文件夹';
    }
    return null;
  }

  Future<String?> _promptName({
    required String title,
    required String confirmLabel,
    String initial = '',
    String? original,
    bool selectStem = false,
  }) {
    final controller = TextEditingController(text: initial);
    final dot = initial.lastIndexOf('.');
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: selectStem && dot > 0 ? dot : initial.length,
    );
    String? error;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final message = _validateName(controller.text, original: original);
            if (message != null) {
              setDialogState(() => error = message);
              return;
            }
            Navigator.pop(dialogContext, controller.text.trim());
          }

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 380,
              child: TextField(
                controller: controller,
                autofocus: true,
                onSubmitted: (_) => submit(),
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
                decoration: InputDecoration(errorText: error, isDense: true),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: Text(confirmLabel)),
            ],
          );
        },
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _createFolder() async {
    final state = _loadedState;
    if (state == null || !state.folderView) return;
    if (!state.currentRootWritable || state.currentRootId != 'fs') {
      _showSnack('这里不能新建文件夹');
      return;
    }
    final cubit = context.read<FileBrowserCubit>();
    final name = await _promptName(
      title: '新建文件夹',
      confirmLabel: '创建',
      initial: _uniqueName('新建文件夹', state),
    );
    if (name == null || !mounted) return;
    final error = await cubit.createFolder(name);
    if (!mounted) return;
    if (error != null) {
      _showSnack('新建文件夹失败：$error');
      return;
    }
    final created = cubit.state;
    if (created is FileBrowserLoaded) {
      final path = created.currentPath.append(name).path;
      _setSelection({path});
    }
  }

  String _uniqueName(String base, FileBrowserLoaded state) {
    final existing = state.allFiles.map((f) => f.name.toLowerCase()).toSet();
    if (!existing.contains(base.toLowerCase())) return base;
    for (var i = 2; ; i++) {
      final candidate = '$base ($i)';
      if (!existing.contains(candidate.toLowerCase())) return candidate;
    }
  }

  Future<void> _renameEntry(FileEntryEntity entry) async {
    final state = _loadedState;
    final cubit = context.read<FileBrowserCubit>();
    if (state == null || !cubit.canMoveEntries) return;
    if (!state.currentRootWritable || state.currentRootId != 'fs') {
      _showSnack('这里的文件不能重命名');
      return;
    }
    final name = await _promptName(
      title: entry.isDirectory ? '重命名文件夹' : '重命名',
      confirmLabel: '重命名',
      initial: entry.name,
      original: entry.name,
      selectStem: !entry.isDirectory,
    );
    if (name == null || name == entry.name || !mounted) return;
    final error = await cubit.renameEntry(entry, name);
    if (!mounted) return;
    if (error != null) _showSnack('重命名失败：$error');
  }

  Future<void> _moveEntriesTo(List<FileEntryEntity> entries) async {
    final state = _loadedState;
    final cubit = context.read<FileBrowserCubit>();
    if (state == null || entries.isEmpty || !cubit.canMoveEntries) return;
    if (!state.currentRootWritable || state.currentRootId != 'fs') {
      _showSnack('这里的文件不能移动');
      return;
    }
    final target = await showDialog<NasPath>(
      context: context,
      builder: (_) => _MoveTargetDialog(
        cubit: cubit,
        rootId: state.currentRootId,
        initialPath: state.folderView
            ? state.currentPath
            : NasPath.root(state.currentRootId),
        movingFolders: entries
            .where((e) => e.isDirectory)
            .map((e) => e.path)
            .toSet(),
        count: entries.length,
      ),
    );
    if (target == null || !mounted) return;
    final message = await cubit.moveEntries(entries, target);
    if (mounted && message.isNotEmpty) _showSnack(message);
  }

  /// 拖入整个文件夹：先在服务器上建好目录结构，再按目录分组排队上传。
  Future<void> _uploadLocalFolders(
    List<String> folders,
    NasPath targetPath,
  ) async {
    final cubit = context.read<FileBrowserCubit>();
    final transferCubit = context.read<TransferCubit>();
    final createFolder = serviceLocator.createFolderUseCase;
    var queued = 0;
    var folderFailures = 0;
    for (final folder in folders) {
      final root = Directory(folder);
      final rootName = root.uri.pathSegments.lastWhere(
        (s) => s.isNotEmpty,
        orElse: () => 'folder',
      );
      final groups = <String, List<String>>{'': <String>[]};
      final directories = <String>[''];
      try {
        await for (final entity in root.list(
          recursive: true,
          followLinks: false,
        )) {
          final relative = entity.path
              .substring(root.path.length)
              .replaceAll('\\', '/')
              .split('/')
              .where((s) => s.isNotEmpty)
              .toList();
          if (relative.isEmpty || relative.any((s) => s.startsWith('.'))) {
            continue;
          }
          if (entity is Directory) {
            directories.add(relative.join('/'));
          } else if (entity is File) {
            final dir = relative.sublist(0, relative.length - 1).join('/');
            groups.putIfAbsent(dir, () => <String>[]).add(entity.path);
          }
        }
      } catch (error) {
        if (mounted) _showSnack('读取文件夹失败：$error');
        continue;
      }

      NasPath remoteFor(String relativeDir) {
        var path = targetPath.append(rootName);
        for (final part in relativeDir.split('/').where((s) => s.isNotEmpty)) {
          path = path.append(part);
        }
        return path;
      }

      directories.sort((a, b) => a.length.compareTo(b.length));
      for (final dir in directories) {
        final result = await createFolder.call(remoteFor(dir));
        final message = result.failureOrNull?.message ?? '';
        if (result.isFailure && !message.contains('status code of 405')) {
          folderFailures += 1;
        } else if (result.isFailure && dir.isEmpty) {
          // 根文件夹 405：可能已存在，也可能服务端太旧，后续上传会给出明确错误
        }
      }
      if (!mounted) return;

      for (final entry in groups.entries) {
        if (entry.value.isEmpty || !mounted) continue;
        final remote = remoteFor(entry.key);
        try {
          final result = await _queueUploadToServerDirectory.queueLocalPaths(
            context,
            transferCubit: transferCubit,
            targetPath: remote,
            paths: entry.value,
          );
          if (!mounted || result == null) continue;
          queued += result.createdTasks.length;
          _handleQueuedUploadResult(
            context,
            transferCubit: transferCubit,
            targetRootId: remote.rootId,
            targetPath: remote,
            result: result,
          );
        } catch (error) {
          if (mounted) _showSnack('上传失败：$error');
        }
      }
    }
    if (!mounted) return;
    final current = cubit.state;
    if (current is FileBrowserLoaded) {
      await cubit.refreshDirectoryEntries(current.currentPath);
    }
    if (!mounted) return;
    if (folderFailures > 0) {
      _showSnack('有 $folderFailures 个文件夹创建失败，请确认手机服务端已升级到 1.1.0');
    } else if (queued > 0) {
      _showSnack('已加入 $queued 个文件到上传队列');
    }
  }

  Widget _buildBreadcrumbBar(
    BuildContext context,
    FileBrowserCubit cubit,
    FileBrowserLoaded state,
  ) {
    final segments = state.currentPath.segments;
    final rootLabel = state.currentRootId == 'library' ? '原机' : '共享';
    final primary = Theme.of(context).colorScheme.primary;
    final canCreate = state.currentRootWritable && state.currentRootId == 'fs';

    Widget crumb(String label, NasPath path, {required bool last}) {
      return TextButton(
        onPressed: last ? null : () => unawaited(cubit.navigateTo(path)),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: DesktopTokens.textSecondary,
          disabledForegroundColor: DesktopTokens.textPrimary,
          // 用主题的 labelLarge 派生，保留 Windows 下的中文字体设置
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: last ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
    }

    final crumbs = <Widget>[
      crumb(
        rootLabel,
        NasPath.root(state.currentRootId),
        last: segments.isEmpty,
      ),
    ];
    var path = NasPath.root(state.currentRootId);
    for (var i = 0; i < segments.length; i++) {
      path = path.append(segments[i]);
      crumbs.add(
        const Icon(
          Icons.chevron_right_rounded,
          size: 16,
          color: DesktopTokens.textTertiary,
        ),
      );
      crumbs.add(crumb(segments[i], path, last: i == segments.length - 1));
    }

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(
        horizontal: DesktopTokens.pagePadding,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: DesktopTokens.border)),
      ),
      child: Row(
        children: [
          ToolbarIconButton(
            icon: Icons.arrow_upward_rounded,
            tooltip: '上一级（Backspace）',
            onPressed: state.currentPath.isRoot
                ? null
                : () => unawaited(cubit.navigateUp()),
          ),
          const SizedBox(width: 4),
          Icon(Icons.folder_open_rounded, size: 18, color: primary),
          const SizedBox(width: 2),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(children: crumbs),
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: canCreate ? () => unawaited(_createFolder()) : null,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('新建文件夹'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 右键菜单
  // ---------------------------------------------------------------------------

  PopupMenuItem<VoidCallback> _menuItem(
    String label,
    IconData icon,
    VoidCallback onTap, {
    String? shortcut,
    bool enabled = true,
    bool danger = false,
  }) {
    final color = danger ? DesktopTokens.danger : DesktopTokens.textPrimary;
    return PopupMenuItem<VoidCallback>(
      value: onTap,
      enabled: enabled,
      height: 36,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: enabled ? color : DesktopTokens.textTertiary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: enabled ? color : null),
            ),
          ),
          if (shortcut != null) ...[
            const SizedBox(width: 24),
            Text(
              shortcut,
              style: const TextStyle(
                fontSize: 12,
                color: DesktopTokens.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showMenuAt(
    Offset globalPosition,
    List<PopupMenuEntry<VoidCallback>> items,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 220),
      items: items,
    );
    selected?.call();
  }

  void _showItemContextMenu(Offset globalPosition) {
    final state = _loadedState;
    if (state == null) return;
    final selected = _selectedFiles(state);
    if (selected.isEmpty) return;
    final single = selected.length == 1 ? selected.first : null;
    final writable = state.currentRootWritable;
    final cubit = context.read<FileBrowserCubit>();
    unawaited(
      _showMenuAt(globalPosition, [
        if (single != null)
          _menuItem(
            single.isImage || single.isVideo ? '预览' : '打开',
            Icons.open_in_new_rounded,
            () => _openFile(single),
            shortcut: 'Enter',
          ),
        _menuItem(
          single != null ? '下载' : '下载 ${selected.length} 项',
          Icons.download_rounded,
          () => _downloadFiles(selected),
        ),
        _menuItem(
          '下载到…',
          Icons.drive_folder_upload_outlined,
          () => _downloadFiles(selected, chooseFolder: true),
        ),
        const PopupMenuDivider(height: 8),
        if (single != null && cubit.canMoveEntries)
          _menuItem(
            '重命名',
            Icons.drive_file_rename_outline_rounded,
            () => _renameEntry(single),
            shortcut: 'F2',
            enabled: writable && state.currentRootId == 'fs',
          ),
        if (cubit.canMoveEntries)
          _menuItem(
            '移动到…',
            Icons.drive_file_move_outline,
            () => _moveEntriesTo(selected),
            enabled: writable && state.currentRootId == 'fs',
          ),
        if (single != null)
          _menuItem('复制文件名', Icons.copy_rounded, () {
            Clipboard.setData(ClipboardData(text: single.name));
          }),
        if (single != null)
          _menuItem('复制路径', Icons.link_rounded, () {
            Clipboard.setData(ClipboardData(text: single.path));
          }),
        _menuItem(
          single != null ? '删除' : '删除 ${selected.length} 项',
          Icons.delete_outline_rounded,
          () => _confirmDelete(selected),
          shortcut: 'Delete',
          enabled: writable,
          danger: true,
        ),
        if (single != null) ...[
          const PopupMenuDivider(height: 8),
          _menuItem(
            '属性',
            Icons.info_outline_rounded,
            () => _showProperties(single),
          ),
        ],
      ]),
    );
  }

  void _showBackgroundContextMenu(Offset globalPosition) {
    final state = _loadedState;
    if (state == null) return;
    final cubit = context.read<FileBrowserCubit>();
    final writable = state.currentRootWritable;
    unawaited(
      _showMenuAt(globalPosition, [
        _menuItem(
          '上传文件…',
          Icons.upload_file_rounded,
          () => _pickAndUploadFiles(context, cubit),
          shortcut: 'Ctrl+U',
          enabled: writable,
        ),
        _menuItem(
          '上传照片/视频…',
          Icons.add_photo_alternate_outlined,
          () => _pickAndUploadMedia(context, cubit),
          enabled: writable,
        ),
        if (state.folderView) ...[
          _menuItem(
            '新建文件夹',
            Icons.create_new_folder_outlined,
            _createFolder,
            shortcut: 'Ctrl+Shift+N',
            enabled: writable && state.currentRootId == 'fs',
          ),
          if (!state.currentPath.isRoot)
            _menuItem(
              '返回上一级',
              Icons.arrow_upward_rounded,
              () => unawaited(cubit.navigateUp()),
              shortcut: 'Backspace',
            ),
        ],
        const PopupMenuDivider(height: 8),
        _menuItem(
          '大图标',
          Icons.grid_view_rounded,
          () => _setViewMode(_ViewMode.grid),
        ),
        _menuItem(
          '详细信息',
          Icons.view_list_rounded,
          () => _setViewMode(_ViewMode.list),
        ),
        const PopupMenuDivider(height: 8),
        _menuItem(
          '全选',
          Icons.select_all_rounded,
          _selectAll,
          shortcut: 'Ctrl+A',
        ),
        _menuItem('刷新', Icons.refresh_rounded, _refresh, shortcut: 'F5'),
      ]),
    );
  }

  // ---------------------------------------------------------------------------
  // 拖放上传
  // ---------------------------------------------------------------------------

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dropHovering = false);
    final state = _loadedState;
    if (state == null) return;
    if (!state.currentRootWritable) {
      _showSnack('当前位置不支持上传');
      return;
    }
    final files = <String>[];
    final folders = <String>[];
    for (final item in details.files) {
      final path = item.path;
      if (path.isEmpty) continue;
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        folders.add(path);
      } else if (type == FileSystemEntityType.file) {
        files.add(path);
      }
    }
    if (folders.isNotEmpty) {
      if (state.currentRootId != 'fs') {
        _showSnack('这里不能上传文件夹，已跳过 ${folders.length} 个文件夹');
      } else {
        await _uploadLocalFolders(folders, state.currentPath);
      }
    }
    if (files.isEmpty || !mounted) return;
    final transferCubit = context.read<TransferCubit>();
    try {
      final result = await _queueUploadToServerDirectory.queueLocalPaths(
        context,
        transferCubit: transferCubit,
        targetPath: state.currentPath,
        paths: files,
      );
      if (!mounted || result == null) return;
      _handleQueuedUploadResult(
        context,
        transferCubit: transferCubit,
        targetRootId: state.currentRootId,
        targetPath: state.currentPath,
        result: result,
      );
    } catch (error) {
      if (mounted) _showSnack('上传失败：$error');
    }
  }

  // ---------------------------------------------------------------------------
  // 预览（沿用移动端图库页，已支持方向键和 Esc）
  // ---------------------------------------------------------------------------

  void _showPreviewDialog(
    BuildContext context,
    FileEntryEntity file,
    FileBrowserLoaded state,
  ) {
    final mediaFiles = state.mediaFiles;

    if (mediaFiles.isEmpty) return;

    final initialIndex = mediaFiles.indexWhere((f) => f.path == file.path);
    if (initialIndex == -1) return;

    final cubit = context.read<FileBrowserCubit>();
    final thumbnails = <String, Uint8List>{};
    for (final f in mediaFiles) {
      final data = cubit.getThumbnail(f.path);
      if (data != null) {
        thumbnails[f.path] = data;
      }
    }

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    Navigator.of(context)
        .push(
          PageRouteBuilder<void>(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 180),
            reverseTransitionDuration: const Duration(milliseconds: 180),
            pageBuilder: (context, animation, secondaryAnimation) {
              return GalleryPage(
                mediaFiles: mediaFiles,
                initialIndex: initialIndex,
                rootId: state.currentRootId,
                thumbnails: thumbnails,
              );
            },
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(
                    opacity: CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOut,
                    ),
                    child: child,
                  );
                },
          ),
        )
        .then((_) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        });
  }

  // ---------------------------------------------------------------------------
  // 上传与上传结果跟踪（与移动端逻辑一致）
  // ---------------------------------------------------------------------------

  Future<void> _pickAndUploadMedia(
    BuildContext context,
    FileBrowserCubit cubit,
  ) async {
    await _queueUploadFromPicker(
      context,
      cubit,
      pickerFailureMessage: '打开图库失败',
      pick: (context, transferCubit, targetPath) =>
          _queueUploadToServerDirectory(
            context,
            transferCubit: transferCubit,
            targetPath: targetPath,
          ),
    );
  }

  Future<void> _pickAndUploadFiles(
    BuildContext context,
    FileBrowserCubit cubit,
  ) async {
    await _queueUploadFromPicker(
      context,
      cubit,
      pickerFailureMessage: '打开文件选择器失败',
      pick: (context, transferCubit, targetPath) =>
          _queueUploadToServerDirectory.pickFilesAndQueue(
            context,
            transferCubit: transferCubit,
            targetPath: targetPath,
          ),
    );
  }

  Future<void> _queueUploadFromPicker(
    BuildContext context,
    FileBrowserCubit cubit, {
    required String pickerFailureMessage,
    required Future<QueuedServerUploadResult?> Function(
      BuildContext context,
      TransferCubit transferCubit,
      NasPath targetPath,
    )
    pick,
  }) async {
    try {
      final state = cubit.state;
      if (state is! FileBrowserLoaded) {
        return;
      }

      if (!state.currentRootWritable) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前目录不支持上传')));
        }
        return;
      }

      final transferCubit = context.read<TransferCubit>();
      final targetRootId = state.currentRootId;
      final targetPath = state.currentPath;
      final result = await pick(context, transferCubit, targetPath);
      if (!context.mounted || result == null) {
        return;
      }

      _handleQueuedUploadResult(
        context,
        transferCubit: transferCubit,
        targetRootId: targetRootId,
        targetPath: targetPath,
        result: result,
      );
    } catch (e) {
      if (context.mounted) {
        final message = _uploadPickerFailureMessage(
          pickerFailureMessage: pickerFailureMessage,
          error: e,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  String _uploadPickerFailureMessage({
    required String pickerFailureMessage,
    required Object error,
  }) {
    final text = error.toString();
    if (text.contains('illegal percent encoding in URI') ||
        text.contains('percent encoding in URI')) {
      return '当前目录路径包含特殊字符，请返回上级目录后重试';
    }
    return '$pickerFailureMessage: $error';
  }

  void _handleQueuedUploadResult(
    BuildContext context, {
    required TransferCubit transferCubit,
    required String targetRootId,
    required NasPath targetPath,
    required QueuedServerUploadResult result,
  }) {
    for (final task in result.createdTasks) {
      _trackedUploadTasks[task.id] = _TrackedUploadTask(
        rootId: targetRootId,
        directoryPath: targetPath.path,
      );
      if (task.status == TransferStatus.awaitingConflictResolution) {
        unawaited(_promptTrackedUploadConflict(context, task));
      }
    }

    _handleTransferStateChanged(context, transferCubit.state);
    showQueuedUploadResultSnackBar(context, result: result);
  }

  void _handleTransferStateChanged(
    BuildContext context,
    TransferState transferState,
  ) {
    if (transferState is! TransferLoaded) {
      return;
    }

    if (_trackedUploadTasks.isNotEmpty) {
      _handleTrackedUploadStateChanged(context, transferState);
    }
  }

  void _handleTrackedUploadStateChanged(
    BuildContext context,
    TransferLoaded transferState,
  ) {
    final fileState = context.read<FileBrowserCubit>().state;
    FileBrowserLoaded? refreshTarget;

    for (final entry in _trackedUploadTasks.entries.toList()) {
      final task = _findTaskById(transferState.tasks, entry.key);
      if (task == null) {
        continue;
      }

      if (task.status == TransferStatus.completed) {
        _completedTrackedUploadCount += 1;
        _trackedUploadTasks.remove(entry.key);
        if (fileState is FileBrowserLoaded &&
            fileState.currentRootId == entry.value.rootId &&
            fileState.currentPath.path == entry.value.directoryPath) {
          _uploadRefreshPending = true;
          refreshTarget = fileState;
        }
      } else if (task.status == TransferStatus.skipped) {
        _skippedTrackedUploadCount += 1;
        _trackedUploadTasks.remove(entry.key);
      } else if (task.status == TransferStatus.awaitingConflictResolution) {
        unawaited(_promptTrackedUploadConflict(context, task));
      } else if (task.status == TransferStatus.failed) {
        _failedTrackedUploadCount += 1;
        final err = task.errorMessage;
        if (err != null && context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('上传失败: $err')));
        }
        _trackedUploadTasks.remove(entry.key);
      }
    }

    if (_trackedUploadTasks.isEmpty && _uploadRefreshPending) {
      _uploadRefreshPending = false;
      if (refreshTarget != null) {
        unawaited(
          context.read<FileBrowserCubit>().refreshDirectoryEntries(
            refreshTarget.currentPath,
          ),
        );
      }
    }

    if (_trackedUploadTasks.isEmpty &&
        (_completedTrackedUploadCount > 0 ||
            _skippedTrackedUploadCount > 0 ||
            _failedTrackedUploadCount > 0)) {
      _showUploadSummary(context);
    }
  }

  Future<void> _promptTrackedUploadConflict(
    BuildContext context,
    TransferTaskEntity task,
  ) async {
    if (!context.mounted) {
      return;
    }
    if (_activeConflictTaskId != null) {
      return;
    }

    _activeConflictTaskId = task.id;
    try {
      final resolution = await showUploadConflictDialog(
        context,
        fileName: task.fileName,
      );
      if (!context.mounted || resolution == null) {
        return;
      }
      await context.read<TransferCubit>().resolveUploadConflict(
        taskId: task.id,
        resolution: resolution,
      );
    } finally {
      _activeConflictTaskId = null;
    }
  }

  TransferTaskEntity? _findTaskById(
    List<TransferTaskEntity> tasks,
    String taskId,
  ) {
    for (final task in tasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  void _showUploadSummary(BuildContext context) {
    if (!context.mounted) {
      return;
    }

    final message = switch ((
      _completedTrackedUploadCount,
      _skippedTrackedUploadCount,
      _failedTrackedUploadCount,
    )) {
      (final completed, 0, 0) when completed == 1 => '上传完成',
      (final completed, 0, 0) => '已完成 $completed 个上传任务',
      (0, final skipped, 0) => '已跳过 $skipped 个重名文件',
      (0, 0, final failed) => '$failed 个上传任务失败',
      (final completed, final skipped, 0) => '已完成 $completed 个，跳过 $skipped 个',
      (final completed, 0, final failed) => '已完成 $completed 个，失败 $failed 个',
      (0, final skipped, final failed) => '已跳过 $skipped 个，失败 $failed 个',
      (final completed, final skipped, final failed) =>
        '已完成 $completed 个，跳过 $skipped 个，失败 $failed 个',
    };

    _completedTrackedUploadCount = 0;
    _skippedTrackedUploadCount = 0;
    _failedTrackedUploadCount = 0;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<FileBrowserCubit, FileBrowserState>(
      listenWhen: (previous, current) {
        if (current is FileBrowserLoaded &&
            current.message != null &&
            current.message!.trim().isNotEmpty &&
            (previous is! FileBrowserLoaded ||
                previous.message != current.message)) {
          return true;
        }
        if (current is! FileBrowserLoaded) return false;
        if (previous is! FileBrowserLoaded) return true;
        return previous.currentPath != current.currentPath ||
            previous.currentRootId != current.currentRootId ||
            previous.currentCategory != current.currentCategory ||
            !identical(previous.filteredFiles, current.filteredFiles);
      },
      listener: (context, state) {
        if (state is FileBrowserLoaded &&
            state.message != null &&
            state.message!.trim().isNotEmpty) {
          _showSnack(state.message!);
        }
        if (state is! FileBrowserLoaded) return;
        final navigationChanged =
            _lastThumbnailNavigationPath != state.currentPath ||
            _lastThumbnailRootId != state.currentRootId ||
            _lastThumbnailCategory != state.currentCategory;
        _lastThumbnailNavigationPath = state.currentPath;
        _lastThumbnailRootId = state.currentRootId;
        _lastThumbnailCategory = state.currentCategory;
        if (navigationChanged) {
          _resetVisibleRangeTracking();
          _anchorPath = null;
          _lastFocusedPath = null;
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        }
        _scheduleVisibleThumbnailRequest();
      },
      builder: (context, state) {
        final cubit = context.read<FileBrowserCubit>();
        return BlocListener<TransferCubit, TransferState>(
          listener: _handleTransferStateChanged,
          child: Focus(
            focusNode: _pageFocusNode,
            autofocus: true,
            onKeyEvent: _onKeyEvent,
            child: ColoredBox(
              color: DesktopTokens.background,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(context, cubit, state),
                  _buildCommandBar(context, cubit, state),
                  if (state is FileBrowserLoaded && state.folderView)
                    _buildBreadcrumbBar(context, cubit, state),
                  if (state is FileBrowserLoaded && _viewMode == _ViewMode.list)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _contentPadding,
                      ),
                      child: DesktopFileListHeader(
                        sortBy: cubit.currentSortBy,
                        sortOrder: cubit.currentSortOrder,
                        onSort: cubit.changeSort,
                      ),
                    ),
                  Expanded(child: _buildContent(context, cubit, state)),
                  _buildStatusBar(context, state),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    FileBrowserCubit cubit,
    FileBrowserState state,
  ) {
    final writable = state is FileBrowserLoaded && state.currentRootWritable;
    return DesktopPageHeader(
      title: '文件',
      subtitle:
          serviceLocator.unifiedNodeStore.currentServer?.identity.displayName,
      actions: [
        SizedBox(
          width: MediaQuery.sizeOf(context).width < 1280 ? 200 : 260,
          height: 36,
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onChanged: _onSearchChanged,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: cubit.isFolderView
                  ? '搜索当前文件夹（Ctrl+F）'
                  : '搜索当前分类（Ctrl+F）',
              hintStyle: const TextStyle(
                fontSize: 13,
                color: DesktopTokens.textTertiary,
              ),
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: DesktopTokens.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: DesktopTokens.border),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: writable ? '上传文件到当前位置（也可以直接把文件拖进窗口）' : '当前位置不支持上传',
          child: PopupMenuButton<int>(
            enabled: writable,
            tooltip: '',
            position: PopupMenuPosition.under,
            onSelected: (value) {
              if (value == 0) {
                unawaited(_pickAndUploadFiles(context, cubit));
              } else {
                unawaited(_pickAndUploadMedia(context, cubit));
              }
            },
            itemBuilder: (_) => [
              _plainMenuItem(0, '上传文件…', Icons.upload_file_rounded, 'Ctrl+U'),
              _plainMenuItem(
                1,
                '上传照片/视频…',
                Icons.add_photo_alternate_outlined,
                null,
              ),
            ],
            child: IgnorePointer(
              child: FilledButton.icon(
                onPressed: writable ? () {} : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('上传'),
                    SizedBox(width: 4),
                    Icon(Icons.expand_more_rounded, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  PopupMenuItem<int> _plainMenuItem(
    int value,
    String label,
    IconData icon,
    String? shortcut,
  ) {
    return PopupMenuItem<int>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 13)),
          if (shortcut != null) ...[
            const SizedBox(width: 24),
            Text(
              shortcut,
              style: const TextStyle(
                fontSize: 12,
                color: DesktopTokens.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCommandBar(
    BuildContext context,
    FileBrowserCubit cubit,
    FileBrowserState state,
  ) {
    final loaded = state is FileBrowserLoaded ? state : null;
    final selected = loaded == null
        ? const <FileEntryEntity>[]
        : _selectedFiles(loaded);
    final writable = loaded?.currentRootWritable ?? false;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(
        horizontal: DesktopTokens.pagePadding,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DesktopTokens.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄窗口（或打开传输面板）时：分类去掉图标、选择操作只显示图标
          final compact = constraints.maxWidth < 1040;
          final tight = constraints.maxWidth < 760;
          Widget action(
            IconData icon,
            String label,
            VoidCallback? onPressed, {
            Color? color,
          }) {
            if (compact) {
              return Tooltip(
                message: label,
                child: IconButton(
                  onPressed: onPressed,
                  color: color ?? Theme.of(context).colorScheme.primary,
                  icon: Icon(icon, size: 19),
                ),
              );
            }
            return TextButton.icon(
              onPressed: onPressed,
              style: color == null
                  ? null
                  : TextButton.styleFrom(foregroundColor: color),
              icon: Icon(icon, size: 18),
              label: Text(label),
            );
          }

          return Row(
            children: [
              DesktopSegmented<String>(
                selected: cubit.isFolderView
                    ? _folderSegment
                    : cubit.currentCategory.name,
                onChanged: loaded == null
                    ? null
                    : (value) {
                        if (value == _folderSegment) {
                          unawaited(cubit.switchToFolderView());
                        } else {
                          unawaited(
                            cubit.switchCategory(
                              FileCategory.values.byName(value),
                            ),
                          );
                        }
                      },
                segments: [
                  DesktopSegment(
                    value: _folderSegment,
                    label: '文件夹',
                    icon: compact ? null : Icons.folder_copy_outlined,
                  ),
                  DesktopSegment(
                    value: FileCategory.photo.name,
                    label: '照片',
                    icon: compact ? null : Icons.image_outlined,
                  ),
                  DesktopSegment(
                    value: FileCategory.video.name,
                    label: '视频',
                    icon: compact ? null : Icons.movie_outlined,
                  ),
                  DesktopSegment(
                    value: FileCategory.document.name,
                    label: '文档',
                    icon: compact ? null : Icons.description_outlined,
                  ),
                  DesktopSegment(
                    value: FileCategory.other.name,
                    label: '其他',
                    icon: compact ? null : Icons.category_outlined,
                  ),
                ],
              ),
              if (loaded != null && _isMobileServer()) ...[
                const SizedBox(width: 12),
                Tooltip(
                  message: '共享：服务器的共享空间；原机：手机本机的相册与文件',
                  waitDuration: const Duration(milliseconds: 600),
                  child: DesktopSegmented<String>(
                    selected: loaded.currentRootId,
                    onChanged: cubit.switchRoot,
                    segments: const [
                      DesktopSegment(value: 'fs', label: '共享'),
                      DesktopSegment(value: 'library', label: '原机'),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              if (selected.isNotEmpty) ...[
                if (!compact) ...[
                  Text(
                    '已选择 ${selected.length} 项',
                    style: const TextStyle(
                      fontSize: 13,
                      color: DesktopTokens.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                action(
                  Icons.download_rounded,
                  '下载',
                  () => _downloadFiles(selected),
                ),
                action(
                  Icons.drive_folder_upload_outlined,
                  '下载到…',
                  () => _downloadFiles(selected, chooseFolder: true),
                ),
                if (cubit.canMoveEntries && loaded!.currentRootId == 'fs')
                  action(
                    Icons.drive_file_move_outline,
                    '移动到…',
                    writable ? () => _moveEntriesTo(selected) : null,
                  ),
                action(
                  Icons.delete_outline_rounded,
                  '删除',
                  writable ? () => _confirmDelete(selected) : null,
                  color: DesktopTokens.danger,
                ),
                ToolbarIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '取消选择（Esc）',
                  onPressed: _clearSelection,
                ),
                const SizedBox(width: 4),
                Container(width: 1, height: 22, color: DesktopTokens.border),
                const SizedBox(width: 4),
              ],
              _SortMenuButton(
                sortBy: cubit.currentSortBy,
                sortOrder: cubit.currentSortOrder,
                onChanged: cubit.changeSort,
                showLabel: !tight,
              ),
              ToolbarIconButton(
                icon: Icons.grid_view_rounded,
                tooltip: '大图标',
                selected: _viewMode == _ViewMode.grid,
                onPressed: () => _setViewMode(_ViewMode.grid),
              ),
              ToolbarIconButton(
                icon: Icons.view_list_rounded,
                tooltip: '详细信息',
                selected: _viewMode == _ViewMode.list,
                onPressed: () => _setViewMode(_ViewMode.list),
              ),
              ToolbarIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新（F5）',
                onPressed: _refresh,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    FileBrowserCubit cubit,
    FileBrowserState state,
  ) {
    if (state is FileBrowserError) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(DesktopTokens.pagePadding),
        child: DesktopContent(
          maxWidth: 560,
          child: _ErrorStateCard(
            message: state.message,
            onRetry: () => cubit.loadRoot(),
          ),
        ),
      );
    }
    if (state is! FileBrowserLoaded) {
      if (state is FileBrowserLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.all(DesktopTokens.pagePadding),
        child: DesktopContent(
          maxWidth: 560,
          child: _EmptyRootCard(onRetry: () => cubit.loadRoot()),
        ),
      );
    }

    final displayed = _displayedFiles(state);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dropHovering = true),
      onDragExited: (_) => setState(() => _dropHovering = false),
      onDragDone: (details) => unawaited(_handleDrop(details)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _updateLayout(constraints.maxWidth);
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onBackgroundPointerDown,
            onPointerMove: _onBackgroundPointerMove,
            onPointerUp: _onBackgroundPointerUp,
            onPointerCancel: _onBackgroundPointerUp,
            onPointerSignal: _onPointerSignal,
            child: Stack(
              children: [
                Positioned.fill(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: Scrollbar(
                      controller: _scrollController,
                      child: CustomScrollView(
                        controller: _scrollController,
                        physics: _ctrlPressed
                            ? const NeverScrollableScrollPhysics()
                            : const ClampingScrollPhysics(),
                        slivers: [
                          if (displayed.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: _EmptyCategoryHint(
                                searching: _searchQuery.trim().isNotEmpty,
                                writable: state.currentRootWritable,
                                folder: state.folderView,
                              ),
                            )
                          else if (_viewMode == _ViewMode.grid)
                            _buildGrid(cubit, state, displayed)
                          else
                            _buildList(cubit, state, displayed),
                          if (state.isLoadingMore)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_marqueeStart != null && _marqueeCurrent != null)
                  _buildMarquee(),
                if (_dropHovering)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: DesktopTokens.selected.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: DesktopTokens.selectedBorder,
                            width: 2,
                          ),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.file_upload_outlined,
                                size: 44,
                                color: DesktopTokens.selectedBorder,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                state.currentRootWritable
                                    ? '松开鼠标即可上传'
                                    : '当前位置不支持上传',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: DesktopTokens.selectedBorder,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMarquee() {
    final scroll = _scrollController.hasClients ? _scrollController.offset : 0;
    final rect = Rect.fromPoints(
      _marqueeStart!,
      _marqueeCurrent!,
    ).shift(Offset(0, -scroll.toDouble()));
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: DesktopTokens.selectedBorder.withValues(alpha: 0.12),
            border: Border.all(
              color: DesktopTokens.selectedBorder.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapItem(FileEntryEntity file, int index, Widget child) {
    return Listener(
      key: ValueKey<String>(file.path),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _onItemPointerDown(event, file, index),
      child: child,
    );
  }

  Widget _buildGrid(
    FileBrowserCubit cubit,
    FileBrowserLoaded state,
    List<FileEntryEntity> displayed,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.all(_contentPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: _gridSpacing,
          crossAxisSpacing: _gridSpacing,
          mainAxisExtent: _tileHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final file = displayed[index];
            return _wrapItem(
              file,
              index,
              DesktopFileGridTile(
                file: file,
                selected: state.selectedPaths.contains(file.path),
                getThumbnail: cubit.getThumbnail,
                watchThumbnail: cubit.watchThumbnail,
              ),
            );
          },
          childCount: displayed.length,
          findChildIndexCallback: (key) {
            if (key is ValueKey<String>) {
              final i = displayed.indexWhere((f) => f.path == key.value);
              return i == -1 ? null : i;
            }
            return null;
          },
        ),
      ),
    );
  }

  Widget _buildList(
    FileBrowserCubit cubit,
    FileBrowserLoaded state,
    List<FileEntryEntity> displayed,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        _contentPadding,
        _listTopPadding,
        _contentPadding,
        _contentPadding,
      ),
      sliver: SliverFixedExtentList(
        itemExtent: DesktopListColumns.rowHeight,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final file = displayed[index];
            return _wrapItem(
              file,
              index,
              DesktopFileListRow(
                file: file,
                selected: state.selectedPaths.contains(file.path),
                getThumbnail: cubit.getThumbnail,
                watchThumbnail: cubit.watchThumbnail,
              ),
            );
          },
          childCount: displayed.length,
          findChildIndexCallback: (key) {
            if (key is ValueKey<String>) {
              final i = displayed.indexWhere((f) => f.path == key.value);
              return i == -1 ? null : i;
            }
            return null;
          },
        ),
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context, FileBrowserState state) {
    final loaded = state is FileBrowserLoaded ? state : null;
    final parts = <String>[];
    if (loaded != null) {
      final displayed = _displayedFiles(loaded);
      final total = loaded.filteredFiles.length;
      if (_searchQuery.trim().isNotEmpty) {
        parts.add('找到 ${displayed.length} 项（共 $total 项）');
      } else {
        parts.add(loaded.hasMore ? '已加载 $total 项，向下滚动加载更多' : '$total 个项目');
      }
      final selected = _selectedFiles(loaded);
      if (selected.isNotEmpty) {
        final bytes = selected.fold<int>(0, (sum, f) => sum + f.size);
        parts.add('已选择 ${selected.length} 项，${formatBytes(bytes)}');
      }
    }
    const textStyle = TextStyle(
      fontSize: 12,
      color: DesktopTokens.textSecondary,
    );
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: DesktopTokens.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join('    '),
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_viewMode == _ViewMode.grid) ...[
            const Icon(
              Icons.photo_size_select_small_rounded,
              size: 14,
              color: DesktopTokens.textTertiary,
            ),
            SizedBox(
              width: 120,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Tooltip(
                  message: '缩略图大小（Ctrl+滚轮）',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Slider(
                    value: _tileExtent,
                    min: _minTileExtent,
                    max: _maxTileExtent,
                    onChanged: (v) => _setTileExtent(v, save: false),
                    onChangeEnd: (_) => unawaited(_saveViewPreferences()),
                  ),
                ),
              ),
            ),
            const Icon(
              Icons.photo_size_select_large_rounded,
              size: 16,
              color: DesktopTokens.textTertiary,
            ),
            const SizedBox(width: 16),
          ],
          BlocBuilder<TransferCubit, TransferState>(
            builder: (context, transferState) {
              final tasks = transferState is TransferLoaded
                  ? transferState.tasks
                  : const <TransferTaskEntity>[];
              final active = tasks.where(isActiveTransfer).toList();
              final uploading = active
                  .where((t) => t.direction == TransferDirection.upload)
                  .length;
              final downloading = active.length - uploading;
              final label = active.isEmpty
                  ? '传输'
                  : [
                      if (uploading > 0) '上传 $uploading',
                      if (downloading > 0) '下载 $downloading',
                    ].join(' · ');
              return TextButton.icon(
                onPressed: DesktopShellState.toggleTransferPanel,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 26),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: active.isEmpty
                      ? DesktopTokens.textSecondary
                      : Theme.of(context).colorScheme.primary,
                  textStyle: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontSize: 12),
                ),
                icon: active.isEmpty
                    ? const Icon(Icons.swap_vert_rounded, size: 16)
                    : const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      ),
                label: Text(label),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EmptyCategoryHint extends StatelessWidget {
  const _EmptyCategoryHint({
    required this.searching,
    required this.writable,
    this.folder = false,
  });

  final bool searching;
  final bool writable;
  final bool folder;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off_rounded : Icons.inbox_outlined,
            size: 48,
            color: DesktopTokens.textTertiary,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? '没有匹配的文件' : (folder ? '这个文件夹是空的' : '这里还没有文件'),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: DesktopTokens.textSecondary,
            ),
          ),
          if (!searching && writable) ...[
            const SizedBox(height: 6),
            Text(
              folder ? '把文件或文件夹拖到这里，或点击右上角“上传”' : '把文件拖到这里，或点击右上角“上传”',
              style: const TextStyle(
                fontSize: 13,
                color: DesktopTokens.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 排序菜单（服务器支持按修改日期、大小排序）。
class _SortMenuButton extends StatelessWidget {
  const _SortMenuButton({
    required this.sortBy,
    required this.sortOrder,
    required this.onChanged,
    this.showLabel = true,
  });

  final bool showLabel;

  final String sortBy;
  final String sortOrder;
  final void Function(String sortBy, String sortOrder) onChanged;

  static const _options = <(String, String, String)>[
    ('modified', 'desc', '修改日期（从新到旧）'),
    ('modified', 'asc', '修改日期（从旧到新）'),
    ('size', 'desc', '大小（从大到小）'),
    ('size', 'asc', '大小（从小到大）'),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return PopupMenuButton<(String, String, String)>(
      tooltip: '排序方式',
      position: PopupMenuPosition.under,
      onSelected: (option) => onChanged(option.$1, option.$2),
      itemBuilder: (context) => [
        for (final option in _options)
          PopupMenuItem<(String, String, String)>(
            value: option,
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: option.$1 == sortBy && option.$2 == sortOrder
                      ? Icon(Icons.check_rounded, size: 18, color: primary)
                      : null,
                ),
                const SizedBox(width: 6),
                Text(option.$3, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sort_rounded,
              size: 20,
              color: DesktopTokens.textSecondary,
            ),
            if (showLabel) const SizedBox(width: 4),
            if (showLabel)
              const Text(
                '排序',
                style: TextStyle(
                  fontSize: 13,
                  color: DesktopTokens.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorStateCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorStateCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('目录加载失败', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('重新加载')),
        ],
      ),
    );
  }
}

class _EmptyRootCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _EmptyRootCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('目录尚未就绪', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '当前还没有拿到可浏览的根目录，确认登录会话后可再次尝试。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: onRetry, child: const Text('再次加载')),
        ],
      ),
    );
  }
}

class _TrackedUploadTask {
  final String rootId;
  final String directoryPath;

  const _TrackedUploadTask({required this.rootId, required this.directoryPath});
}

/// “移动到…”对话框：逐级浏览服务器上的文件夹，选中目标位置。
class _MoveTargetDialog extends StatefulWidget {
  const _MoveTargetDialog({
    required this.cubit,
    required this.rootId,
    required this.initialPath,
    required this.movingFolders,
    required this.count,
  });

  final FileBrowserCubit cubit;
  final String rootId;
  final NasPath initialPath;
  final Set<String> movingFolders;
  final int count;

  @override
  State<_MoveTargetDialog> createState() => _MoveTargetDialogState();
}

class _MoveTargetDialogState extends State<_MoveTargetDialog> {
  late NasPath _path = widget.initialPath;
  List<FileEntryEntity> _folders = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load(_path));
  }

  Future<void> _load(NasPath path) async {
    setState(() {
      _path = path;
      _loading = true;
    });
    final folders = await widget.cubit.listSubfolders(path);
    if (!mounted || _path != path) return;
    setState(() {
      _folders = folders
          .where((f) => !widget.movingFolders.contains(f.path))
          .toList(growable: false);
      _loading = false;
    });
  }

  bool get _targetInvalid => widget.movingFolders.any(
    (p) => _path.path == p || _path.path.startsWith('$p/'),
  );

  @override
  Widget build(BuildContext context) {
    final label = _path.isRoot ? '共享（根目录）' : _path.path.substring(1);
    return AlertDialog(
      title: Text('移动 ${widget.count} 项到…'),
      content: SizedBox(
        width: 440,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ToolbarIconButton(
                  icon: Icons.arrow_upward_rounded,
                  tooltip: '上一级',
                  onPressed: _path.isRoot
                      ? null
                      : () => unawaited(_load(_path.parent())),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: DesktopTokens.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _folders.isEmpty
                    ? const Center(
                        child: Text(
                          '这里没有子文件夹',
                          style: TextStyle(color: DesktopTokens.textTertiary),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _folders.length,
                        itemBuilder: (context, index) {
                          final folder = _folders[index];
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            leading: const Icon(
                              Icons.folder_rounded,
                              color: Color(0xFF3D8A5A),
                            ),
                            title: Text(
                              folder.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                            ),
                            onTap: () => unawaited(
                              _load(
                                NasPath(
                                  rootId: widget.rootId,
                                  path: folder.path,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading || _targetInvalid
              ? null
              : () => Navigator.pop(context, _path),
          child: const Text('移动到这里'),
        ),
      ],
    );
  }
}
