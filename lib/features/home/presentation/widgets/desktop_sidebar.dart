/// 文件职责：Windows 桌面端左侧导航栏（替代移动端底部 Tab 栏）
///   - 概览 / 文件 / 设备 / 设置，Ctrl+1~4 快捷切换；可折叠为图标栏（记住状态）
///   - 「传输」按钮打开右侧传输面板（Ctrl+J），显示进行中的任务数
///   - 底部为当前服务器与连接状态，点击可重新连接、切换服务器、断开并返回登录
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/desktop/desktop_ui.dart';
import '../../../../core/realtime/realtime_connection_state.dart';
import '../../../dashboard/presentation/cubit/dashboard_cubit.dart';
import '../../../dashboard/presentation/cubit/dashboard_state.dart';
import '../../../transfer/presentation/cubit/transfer_cubit.dart';
import '../../../transfer/presentation/cubit/transfer_state.dart';
import '../../../transfer/presentation/widgets/desktop_transfer_panel.dart';

class DesktopSidebar extends StatefulWidget {
  const DesktopSidebar({
    super.key,
    required this.selectedIndex,
    required this.deviceTabUnread,
    required this.onSelect,
    required this.onReconnect,
    required this.onSwitchServer,
    required this.onSignOut,
  });

  final int selectedIndex;
  final int deviceTabUnread;
  final ValueChanged<int> onSelect;
  final Future<void> Function() onReconnect;
  final VoidCallback onSwitchServer;
  final VoidCallback onSignOut;

  @override
  State<DesktopSidebar> createState() => _DesktopSidebarState();
}

class _DesktopSidebarState extends State<DesktopSidebar> {
  static const String _prefCollapsed = 'desktop_sidebar_collapsed';
  static const double _expandedWidth = 216;
  static const double _collapsedWidth = 64;

  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final collapsed = prefs.getBool(_prefCollapsed) ?? false;
      if (mounted && collapsed != _collapsed) {
        setState(() => _collapsed = collapsed);
      }
    } catch (_) {}
  }

  Future<void> _toggle() async {
    setState(() => _collapsed = !_collapsed);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefCollapsed, _collapsed);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final collapsed = _collapsed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      width: collapsed ? _collapsedWidth : _expandedWidth,
      decoration: const BoxDecoration(
        color: Color(0xFFECEAE5),
        border: Border(right: BorderSide(color: DesktopTokens.border)),
      ),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: collapsed ? _collapsedWidth : _expandedWidth,
          maxWidth: collapsed ? _collapsedWidth : _expandedWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: DesktopTokens.headerHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      ToolbarIconButton(
                        icon: Icons.menu_rounded,
                        tooltip: collapsed ? '展开导航栏' : '收起导航栏',
                        onPressed: _toggle,
                      ),
                      if (!collapsed) ...[
                        const SizedBox(width: 8),
                        const Text(
                          '铥棒文件',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: DesktopTokens.textPrimary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              _NavItem(
                icon: Icons.dns_outlined,
                selectedIcon: Icons.dns_rounded,
                label: '概览',
                shortcut: 'Ctrl+1',
                collapsed: collapsed,
                selected: widget.selectedIndex == 0,
                onTap: () => widget.onSelect(0),
              ),
              _NavItem(
                icon: Icons.folder_outlined,
                selectedIcon: Icons.folder_rounded,
                label: '文件',
                shortcut: 'Ctrl+2',
                collapsed: collapsed,
                selected: widget.selectedIndex == 1,
                onTap: () => widget.onSelect(1),
              ),
              _NavItem(
                icon: Icons.devices_outlined,
                selectedIcon: Icons.devices_rounded,
                label: '设备',
                shortcut: 'Ctrl+3',
                collapsed: collapsed,
                badgeCount: widget.deviceTabUnread,
                selected: widget.selectedIndex == 2,
                onTap: () => widget.onSelect(2),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: '设置',
                shortcut: 'Ctrl+4',
                collapsed: collapsed,
                selected: widget.selectedIndex == 3,
                onTap: () => widget.onSelect(3),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Divider(height: 1, color: DesktopTokens.border),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: DesktopShellState.transferPanelOpen,
                builder: (context, open, _) {
                  return BlocBuilder<TransferCubit, TransferState>(
                    builder: (context, state) {
                      final active = state is TransferLoaded
                          ? state.tasks.where(isActiveTransfer).length
                          : 0;
                      return _NavItem(
                        icon: Icons.swap_vert_rounded,
                        selectedIcon: Icons.swap_vert_rounded,
                        label: '传输',
                        shortcut: 'Ctrl+J',
                        collapsed: collapsed,
                        badgeCount: active,
                        selected: open,
                        onTap: DesktopShellState.toggleTransferPanel,
                      );
                    },
                  );
                },
              ),
              const Spacer(),
              _ServerStatusTile(
                collapsed: collapsed,
                onReconnect: widget.onReconnect,
                onSwitchServer: widget.onSwitchServer,
                onSignOut: widget.onSignOut,
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.shortcut,
    required this.collapsed,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String shortcut;
  final bool collapsed;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final selected = widget.selected;
    final color = selected ? primary : const Color(0xFF4A4945);
    final badge = widget.badgeCount <= 0
        ? null
        : widget.badgeCount > 99
        ? '99+'
        : '${widget.badgeCount}';
    Widget icon = Icon(
      selected ? widget.selectedIcon : widget.icon,
      size: 20,
      color: color,
    );
    if (badge != null && widget.collapsed) {
      icon = Badge(label: Text(badge), child: icon);
    }

    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white
                : _hovered
                ? const Color(0xFFE2DFD9)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: selected ? primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(width: widget.collapsed ? 10 : 11),
              icon,
              if (!widget.collapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );

    return Tooltip(
      message: widget.collapsed
          ? '${widget.label}（${widget.shortcut}）'
          : widget.shortcut,
      waitDuration: const Duration(milliseconds: 700),
      preferBelow: false,
      child: tile,
    );
  }
}

class _ServerStatusTile extends StatelessWidget {
  const _ServerStatusTile({
    required this.collapsed,
    required this.onReconnect,
    required this.onSwitchServer,
    required this.onSignOut,
  });

  final bool collapsed;
  final Future<void> Function() onReconnect;
  final VoidCallback onSwitchServer;
  final VoidCallback onSignOut;

  (String, Color) _status(RealtimeConnectionStatus status) {
    switch (status) {
      case RealtimeConnectionStatus.connected:
        return ('已连接', const Color(0xFF3D8A5A));
      case RealtimeConnectionStatus.connecting:
        return ('连接中…', const Color(0xFFD08A31));
      case RealtimeConnectionStatus.reconnecting:
        return ('重连中…', const Color(0xFFD08A31));
      case RealtimeConnectionStatus.disconnected:
        return ('已断开', DesktopTokens.danger);
      case RealtimeConnectionStatus.idle:
        return ('未连接', const Color(0xFF8B867C));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DashboardCubit, DashboardState>(
      builder: (context, state) {
        final realtime = state is DashboardLoaded
            ? state.realtimeConnectionStatus
            : RealtimeConnectionStatus.connecting;
        final (label, color) = _status(realtime);
        final serverName =
            serviceLocator.unifiedNodeStore.currentServer?.identity.displayName;
        final name = serverName == null || serverName.isEmpty
            ? 'NAS 服务器'
            : serverName;

        return PopupMenuButton<int>(
          tooltip: '$name · $label',
          position: PopupMenuPosition.over,
          offset: const Offset(8, -150),
          onSelected: (value) {
            switch (value) {
              case 0:
                unawaited(onReconnect());
              case 1:
                onSwitchServer();
              case 2:
                onSignOut();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 0,
              height: 36,
              child: Row(
                children: [
                  Icon(Icons.refresh_rounded, size: 18),
                  SizedBox(width: 12),
                  Text('重新连接', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            PopupMenuItem(
              value: 1,
              height: 36,
              child: Row(
                children: [
                  Icon(Icons.swap_horiz_rounded, size: 18),
                  SizedBox(width: 12),
                  Text('切换服务器…', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            PopupMenuDivider(height: 8),
            PopupMenuItem(
              value: 2,
              height: 36,
              child: Row(
                children: [
                  Icon(
                    Icons.logout_rounded,
                    size: 18,
                    color: DesktopTokens.danger,
                  ),
                  SizedBox(width: 12),
                  Text(
                    '断开并返回登录',
                    style: TextStyle(fontSize: 13, color: DesktopTokens.danger),
                  ),
                ],
              ),
            ),
          ],
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 12,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: DesktopTokens.border),
            ),
            child: Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(
                      Icons.storage_rounded,
                      size: 22,
                      color: Color(0xFF4A4945),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: DesktopTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          style: TextStyle(fontSize: 11.5, color: color),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.unfold_more_rounded,
                    size: 16,
                    color: DesktopTokens.textTertiary,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
