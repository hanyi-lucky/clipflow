# History Search & Preview Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add history search, type/device filtering, expand/collapse preview, and image grid scaffold to ClipFlow.

**Architecture:** Provider layer manages search/filter state (`_searchQuery`, `_activeTypeFilter`, `_activeDeviceFilter`), exposes `filteredHistory` getter. UI binds to `filteredHistory` instead of `history`. HistoryService is untouched — search is pure in-memory filtering.

**Tech Stack:** Flutter, Provider (ChangeNotifier), Material Design 3

## Global Constraints

- No FOREIGN KEY constraints on any table
- `ContentType` enum: `text`, `image`, `file` — only `text` active in v1.2
- Server stores ciphertext — all search is client-side on decrypted data
- Max 200 entries loaded into memory — no pagination or debounce needed
- Search/merge mode mutually exclusive — never both active
- v1.2 ImageGridView is a scaffold only (empty state message), filled in v1.3

---

### Task 1: Search/Filter State in ClipboardProvider

**Files:**
- Modify: `lib/providers/clipboard_provider.dart`
- Test: `test/providers/clipboard_provider_search_test.dart`

**Interfaces:**
- Consumes: `HistoryService.entries` (existing)
- Produces: `filteredHistory`, `availableDevices`, `setSearchQuery()`, `setTypeFilter()`, `setDeviceFilter()`, `clearFilters()`, `hasActiveFilters`

- [ ] **Step 1: Write failing tests for filteredHistory**

Create `test/providers/clipboard_provider_search_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/services/history_service.dart';

void main() {
  late HistoryService service;

  final macEntry = ClipboardEntry(
    id: '1', content: 'Hello from Mac', sourceDeviceId: 'd1',
    sourceDeviceName: 'MacBook Pro', timestamp: DateTime(2024, 1, 1),
    type: ContentType.text,
  );
  final androidEntry = ClipboardEntry(
    id: '2', content: 'Link from Android', sourceDeviceId: 'd2',
    sourceDeviceName: 'Pixel 7', timestamp: DateTime(2024, 1, 2),
    type: ContentType.text,
  );
  final imageEntry = ClipboardEntry(
    id: '3', content: 'image_data', sourceDeviceId: 'd1',
    sourceDeviceName: 'MacBook Pro', timestamp: DateTime(2024, 1, 3),
    type: ContentType.image,
  );

  setUp(() {
    service = HistoryService(maxEntries: 100);
    service.addEntry(macEntry);
    service.addEntry(androidEntry);
    service.addEntry(imageEntry);
  });

  group('filteredHistory', () {
    test('returns all entries when no filters active', () {
      expect(service.entries.length, equals(3));
    });

    test('filters by content type', () {
      final filtered = service.entries.where((e) => e.type == ContentType.text).toList();
      expect(filtered.length, equals(2));
    });

    test('filters by device name', () {
      final filtered = service.entries.where((e) => e.sourceDeviceName == 'MacBook Pro').toList();
      expect(filtered.length, equals(2));
    });

    test('filters by search query (case-insensitive)', () {
      final query = 'hello';
      final filtered = service.entries.where((e) =>
        e.type == ContentType.text && e.content.toLowerCase().contains(query)
      ).toList();
      expect(filtered.length, equals(1));
      expect(filtered.first.id, equals('1'));
    });

    test('image entries do not match text search', () {
      final query = 'image';
      final filtered = service.entries.where((e) =>
        e.type == ContentType.text && e.content.toLowerCase().contains(query)
      ).toList();
      expect(filtered.length, equals(0));
    });

    test('combined type + device filter', () {
      var results = service.entries;
      results = results.where((e) => e.type == ContentType.text).toList();
      results = results.where((e) => e.sourceDeviceName == 'MacBook Pro').toList();
      expect(results.length, equals(1));
      expect(results.first.id, equals('1'));
    });

    test('available devices are unique', () {
      final devices = service.entries.map((e) => e.sourceDeviceName).toSet().toList();
      expect(devices.length, equals(2));
      expect(devices, containsAll(['MacBook Pro', 'Pixel 7']));
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they pass (testing filter logic directly)**

Run: `flutter test test/providers/clipboard_provider_search_test.dart`
Expected: PASS (tests validate filter logic on HistoryService directly)

- [ ] **Step 3: Add search state to ClipboardProvider**

In `lib/providers/clipboard_provider.dart`, add after line 73 (`String _mergeSeparator = '\n';`):

```dart
  // Search/filter state
  String _searchQuery = '';
  ContentType? _activeTypeFilter;
  String? _activeDeviceFilter;
```

Add after the `serverConnected` getter (line 87):

```dart
  bool get hasActiveFilters =>
      _searchQuery.isNotEmpty || _activeTypeFilter != null || _activeDeviceFilter != null;

  List<ClipboardEntry> get filteredHistory {
    var results = _historyService.entries;

    // Type filter
    if (_activeTypeFilter != null) {
      results = results.where((e) => e.type == _activeTypeFilter).toList();
    }

    // Device filter
    if (_activeDeviceFilter != null) {
      results = results.where((e) => e.sourceDeviceName == _activeDeviceFilter).toList();
    }

    // Keyword search (fuzzy, case-insensitive)
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      results = results.where((e) {
        switch (e.type) {
          case ContentType.text:
            return e.content.toLowerCase().contains(query);
          case ContentType.image:
            return false;
          case ContentType.file:
            return false; // v1.4: match by fileName
        }
      }).toList();
    }

    return results;
  }

  List<String> get availableDevices {
    return _historyService.entries
        .map((e) => e.sourceDeviceName)
        .toSet()
        .toList();
  }
```

Add after the `setSeparator` method (around line 648):

```dart
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setTypeFilter(ContentType? type) {
    _activeTypeFilter = type;
    notifyListeners();
  }

  void setDeviceFilter(String? device) {
    _activeDeviceFilter = device;
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _activeTypeFilter = null;
    _activeDeviceFilter = null;
    notifyListeners();
  }
```

- [ ] **Step 4: Run tests to verify no regressions**

Run: `flutter test test/providers/clipboard_provider_search_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/providers/clipboard_provider.dart test/providers/clipboard_provider_search_test.dart
git commit -m "feat: add search/filter state to ClipboardProvider"
```

---

### Task 2: SearchBar Widget

**Files:**
- Create: `lib/widgets/search_bar.dart`

**Interfaces:**
- Consumes: `ClipboardProvider.filteredHistory`, `setSearchQuery()`, `setTypeFilter()`, `setDeviceFilter()`, `clearFilters()`, `hasActiveFilters`, `availableDevices`, `isMergeMode`
- Produces: `SearchBar` widget, `FilterSheet` callback trigger

- [ ] **Step 1: Create SearchBar widget**

Create `lib/widgets/search_bar.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';
import '../models/clipboard_entry.dart';
import 'filter_sheet.dart';

class HistorySearchBar extends StatefulWidget {
  const HistorySearchBar({super.key});

  @override
  State<HistorySearchBar> createState() => _HistorySearchBarState();
}

class _HistorySearchBarState extends State<HistorySearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => const FilterSheet(),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
    );
  }

  String _typeFilterLabel(ContentType? type) {
    switch (type) {
      case ContentType.text:
        return '▼ 文本';
      case ContentType.image:
        return '▼ 图片';
      case ContentType.file:
        return '▼ 文件';
      default:
        return '▼ 全部';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        if (provider.isMergeMode) return const SizedBox.shrink();

        final theme = Theme.of(context);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withOpacity(0.2),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 20, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: '搜索历史...',
                    hintStyle: TextStyle(color: theme.colorScheme.outline),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: theme.textTheme.bodyMedium,
                  onChanged: (value) => provider.setSearchQuery(value),
                ),
              ),
              if (provider.hasActiveFilters || _controller.text.isNotEmpty)
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: theme.colorScheme.outline),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    _controller.clear();
                    provider.clearFilters();
                    _focusNode.unfocus();
                  },
                ),
              const SizedBox(width: 4),
              // Type filter dropdown
              PopupMenuButton<ContentType?>(
                onSelected: (type) => provider.setTypeFilter(type),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: null, child: Text('全部')),
                  const PopupMenuItem(value: ContentType.text, child: Text('文本')),
                  PopupMenuItem(
                    value: ContentType.image,
                    enabled: false,
                    child: Row(
                      children: [
                        const Text('图片'),
                        const SizedBox(width: 4),
                        Icon(Icons.lock, size: 14, color: theme.colorScheme.outline),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: ContentType.file,
                    enabled: false,
                    child: Row(
                      children: [
                        const Text('文件'),
                        const SizedBox(width: 4),
                        Icon(Icons.lock, size: 14, color: theme.colorScheme.outline),
                      ],
                    ),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: provider.activeTypeFilter != null
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _typeFilterLabel(provider.activeTypeFilter),
                    style: TextStyle(
                      fontSize: 12,
                      color: provider.activeTypeFilter != null
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Device filter button
              IconButton(
                icon: Icon(
                  Icons.tune_rounded,
                  size: 20,
                  color: provider.activeDeviceFilter != null
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: _showFilterSheet,
                tooltip: '筛选设备',
              ),
            ],
          ),
        );
      },
    );
  }
}
```

**Note:** The `PopupMenuButton` references `provider.activeTypeFilter` — we need to add public getters for the filter state. Add to ClipboardProvider after `hasActiveFilters`:

```dart
  ContentType? get activeTypeFilter => _activeTypeFilter;
  String? get activeDeviceFilter => _activeDeviceFilter;
  String get searchQuery => _searchQuery;
```

- [ ] **Step 2: Verify build**

Run: `flutter analyze lib/widgets/search_bar.dart`
Expected: No errors (warnings OK)

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/search_bar.dart lib/providers/clipboard_provider.dart
git commit -m "feat: add HistorySearchBar widget"
```

---

### Task 3: FilterSheet Widget

**Files:**
- Create: `lib/widgets/filter_sheet.dart`

**Interfaces:**
- Consumes: `ClipboardProvider.availableDevices`, `activeDeviceFilter`, `setDeviceFilter()`
- Produces: `FilterSheet` widget (used by `HistorySearchBar`)

- [ ] **Step 1: Create FilterSheet widget**

Create `lib/widgets/filter_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';

class FilterSheet extends StatelessWidget {
  const FilterSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        final theme = Theme.of(context);
        final devices = provider.availableDevices;
        final selected = provider.activeDeviceFilter;

        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '筛选设备',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              _FilterOption(
                label: '全部设备',
                isSelected: selected == null,
                onTap: () {
                  provider.setDeviceFilter(null);
                  Navigator.pop(context);
                },
              ),
              ...devices.map((device) => _FilterOption(
                label: device,
                isSelected: selected == device,
                onTap: () {
                  provider.setDeviceFilter(device);
                  Navigator.pop(context);
                },
              )),
            ],
          ),
        );
      },
    );
  }
}

class _FilterOption extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: isSelected ? theme.colorScheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify build**

Run: `flutter analyze lib/widgets/filter_sheet.dart`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/filter_sheet.dart
git commit -m "feat: add FilterSheet widget for device filtering"
```

---

### Task 4: Integrate SearchBar into HomeScreen

**Files:**
- Modify: `lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `HistorySearchBar`, `ClipboardProvider.filteredHistory`, `hasActiveFilters`
- Produces: Updated HomeScreen with SearchBar and filtered data binding

- [ ] **Step 1: Update HomeScreen to use SearchBar and filteredHistory**

In `lib/screens/home_screen.dart`:

1. Add import at top:
```dart
import '../widgets/search_bar.dart';
```

2. Replace the `SliverAppBar` section — add `HistorySearchBar` after it. In the `CustomScrollView` slivers list, after the `SliverAppBar(...)` closing, add:

```dart
                    const SliverToBoxAdapter(
                      child: HistorySearchBar(),
                    ),
```

3. In the `Consumer<ClipboardProvider>` builder (line 93-173), change `provider.history` to `provider.filteredHistory` (line 95):

```dart
                        final history = provider.filteredHistory;
```

4. Add results count indicator. After `if (history.isEmpty)` block, add before `return SliverList(...)`:

```dart
                        final resultCount = provider.hasActiveFilters
                            ? SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                  child: Text(
                                    '${history.length} 条结果',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.outline,
                                    ),
                                  ),
                                ),
                              )
                            : null;
```

Actually, this is complex to interleave with the existing code. Simpler approach — add the count as a separate sliver before the list. Restructure the Consumer to:

```dart
                    Consumer<ClipboardProvider>(
                      builder: (context, provider, _) {
                        final history = provider.filteredHistory;

                        if (history.isEmpty && provider.hasActiveFilters) {
                          return SliverFillRemaining(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.search_off, size: 64,
                                    color: Theme.of(context).colorScheme.outlineVariant),
                                  const SizedBox(height: 12),
                                  Text('没有找到匹配的记录',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.outline)),
                                ],
                              ),
                            ),
                          );
                        }

                        if (history.isEmpty) {
                          return SliverFillRemaining(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.content_paste_search, size: 80,
                                    color: Theme.of(context).colorScheme.outlineVariant),
                                  const SizedBox(height: 16),
                                  Text('暂无剪切板记录',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.outline)),
                                  const SizedBox(height: 8),
                                  Text('复制内容后自动同步',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.outlineVariant)),
                                ],
                              ),
                            ),
                          );
                        }

                        return SliverMainAxisGroup(
                          slivers: [
                            if (provider.hasActiveFilters)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                  child: Text(
                                    '${history.length} 条结果',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final entry = history[index];
                                  final isSelected = provider.selectedIds.contains(entry.id);
                                  final orderList = provider.selectedIds.toList();
                                  final order = isSelected ? orderList.indexOf(entry.id) + 1 : null;

                                  return ClipboardItem(
                                    entry: entry,
                                    isMergeMode: provider.isMergeMode,
                                    isSelected: isSelected,
                                    selectionOrder: order,
                                    onTap: provider.isMergeMode
                                        ? () => provider.toggleSelection(entry.id)
                                        : null,
                                    onCopy: () => provider.copyEntry(entry.id),
                                    onPin: () => provider.togglePin(entry.id),
                                    onDelete: () {
                                      showDialog(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('删除'),
                                          content: const Text('确定要删除这条记录吗？'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(ctx),
                                              child: const Text('取消'),
                                            ),
                                            TextButton(
                                              onPressed: () {
                                                provider.removeEntry(entry.id);
                                                Navigator.pop(ctx);
                                              },
                                              child: const Text('删除', style: TextStyle(color: Colors.red)),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                                childCount: history.length,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
```

- [ ] **Step 2: Run flutter analyze**

Run: `flutter analyze lib/screens/home_screen.dart`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add lib/screens/home_screen.dart
git commit -m "feat: integrate SearchBar and filteredHistory into HomeScreen"
```

---

### Task 5: ClipboardItem Expand/Collapse

**Files:**
- Modify: `lib/widgets/clipboard_item.dart`

**Interfaces:**
- Consumes: `ClipboardEntry.content` (existing)
- Produces: Expand/collapse state (local `_isExpanded`), optional `searchQuery` for highlight

- [ ] **Step 1: Convert ClipboardItem to StatefulWidget and add expand/collapse**

Rewrite `lib/widgets/clipboard_item.dart`. The full file:

```dart
import 'package:flutter/material.dart';
import '../models/clipboard_entry.dart';

class ClipboardItem extends StatefulWidget {
  final ClipboardEntry entry;
  final bool isMergeMode;
  final bool isSelected;
  final int? selectionOrder;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;
  final String? searchQuery;

  const ClipboardItem({
    super.key,
    required this.entry,
    this.isMergeMode = false,
    this.isSelected = false,
    this.selectionOrder,
    this.onTap,
    this.onCopy,
    this.onPin,
    this.onDelete,
    this.searchQuery,
  });

  @override
  State<ClipboardItem> createState() => _ClipboardItemState();
}

class _ClipboardItemState extends State<ClipboardItem> {
  bool _isExpanded = false;

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  IconData _getDeviceIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'macos': return Icons.laptop_mac;
      case 'windows': return Icons.laptop;
      case 'android': return Icons.phone_android;
      case 'ios': return Icons.phone_iphone;
      default: return Icons.device_unknown;
    }
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final content = widget.entry.content;
    final query = widget.searchQuery?.toLowerCase();

    // Build text spans with optional highlight
    TextSpan buildHighlightedText() {
      if (query == null || query.isEmpty) {
        return TextSpan(
          text: content,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        );
      }

      final spans = <TextSpan>[];
      final lowerContent = content.toLowerCase();
      int start = 0;

      while (true) {
        final index = lowerContent.indexOf(query, start);
        if (index == -1) {
          if (start < content.length) {
            spans.add(TextSpan(
              text: content.substring(start),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ));
          }
          break;
        }
        if (index > start) {
          spans.add(TextSpan(
            text: content.substring(start, index),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ));
        }
        spans.add(TextSpan(
          text: content.substring(index, index + query.length),
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.5,
            backgroundColor: theme.colorScheme.primary.withOpacity(0.25),
            color: theme.colorScheme.primary,
          ),
        ));
        start = index + query.length;
      }

      return TextSpan(children: spans);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Check if content exceeds 3 lines
          final textSpan = buildHighlightedText();
          final textPainter = TextPainter(
            text: textSpan,
            maxLines: 3,
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);

          final isOverflow = textPainter.didExceedMaxLines;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: textSpan,
                maxLines: _isExpanded ? null : 3,
                overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
              if (isOverflow)
                GestureDetector(
                  onTap: () => setState(() => _isExpanded = !_isExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _isExpanded ? '折叠 ▲' : '展开 ▼',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (widget.isMergeMode)
                    Checkbox(
                      value: widget.isSelected,
                      onChanged: (_) => widget.onTap?.call(),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    )
                  else if (widget.selectionOrder != null)
                    Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${widget.selectionOrder}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  Icon(
                    _getDeviceIcon(widget.entry.sourcePlatform),
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.entry.sourceDeviceName} · ${_formatTime(widget.entry.timestamp)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.entry.isPinned)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin, size: 12, color: Colors.orange),
                          SizedBox(width: 2),
                          Text('置顶', style: TextStyle(fontSize: 10, color: Colors.orange)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _buildContent(context),
              if (!widget.isMergeMode) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _ActionChip(
                      icon: widget.entry.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      label: widget.entry.isPinned ? '取消置顶' : '置顶',
                      onTap: widget.onPin,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.copy_rounded,
                      label: '复制',
                      onTap: widget.onCopy,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.delete_outline_rounded,
                      label: '删除',
                      onTap: widget.onDelete,
                      isDestructive: true,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool isDestructive;

  const _ActionChip({
    required this.icon,
    required this.label,
    this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isDestructive ? Colors.red : theme.colorScheme.outline;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Update HomeScreen to pass searchQuery to ClipboardItem**

In `lib/screens/home_screen.dart`, update the `ClipboardItem` constructor call to include `searchQuery`:

```dart
                                  return ClipboardItem(
                                    entry: entry,
                                    isMergeMode: provider.isMergeMode,
                                    isSelected: isSelected,
                                    selectionOrder: order,
                                    searchQuery: provider.searchQuery,
                                    // ... rest unchanged
```

- [ ] **Step 3: Run flutter analyze**

Run: `flutter analyze lib/widgets/clipboard_item.dart lib/screens/home_screen.dart`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/clipboard_item.dart lib/screens/home_screen.dart
git commit -m "feat: expand/collapse preview and search highlight in ClipboardItem"
```

---

### Task 6: ImageGridView Scaffold

**Files:**
- Create: `lib/widgets/image_grid_view.dart`

**Interfaces:**
- Consumes: `ClipboardEntry` list (filtered to `ContentType.image`)
- Produces: `ImageGridView` widget (scaffold with empty state in v1.2)

- [ ] **Step 1: Create ImageGridView widget**

Create `lib/widgets/image_grid_view.dart`:

```dart
import 'package:flutter/material.dart';
import '../models/clipboard_entry.dart';

class ImageGridView extends StatelessWidget {
  final List<ClipboardEntry> entries;

  const ImageGridView({super.key, required this.entries});

  String _formatAbsoluteTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entryDay = DateTime(time.year, time.month, time.day);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (entryDay == today) return timeStr;
    if (entryDay == today.subtract(const Duration(days: 1))) return '昨天 $timeStr';
    return '${time.month}月${time.day}日 $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, size: 64,
              color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              '暂无图片记录',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '图片同步将在 v1.3 支持',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _getCrossAxisCount(context),
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _ImageGridItem(
          entry: entry,
          timeLabel: _formatAbsoluteTime(entry.timestamp),
          onTap: () => _showPreview(context, entry),
        );
      },
    );
  }

  int _getCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width > 900) return 4;
    if (width > 600) return 3;
    return 2;
  }

  void _showPreview(BuildContext context, ClipboardEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            // Placeholder for image
            Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(Icons.image, size: 80, color: Colors.white30),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    // v1.3: copy image to clipboard
                    Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _ImageGridItem extends StatelessWidget {
  final ClipboardEntry entry;
  final String timeLabel;
  final VoidCallback onTap;

  const _ImageGridItem({
    required this.entry,
    required this.timeLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Placeholder (v1.3: actual thumbnail)
              Center(
                child: Icon(
                  Icons.image,
                  size: 40,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              // Time label
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Text(
                    timeLabel,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              // Pin badge
              if (entry.isPinned)
                Positioned(
                  top: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.push_pin, size: 12, color: Colors.orange),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run flutter analyze**

Run: `flutter analyze lib/widgets/image_grid_view.dart`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/image_grid_view.dart
git commit -m "feat: add ImageGridView scaffold (v1.2 placeholder)"
```

---

### Task 7: Wire Up Display Mode Switching

**Files:**
- Modify: `lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `ClipboardProvider.activeTypeFilter`, `filteredHistory`, `ImageGridView`
- Produces: Automatic list/grid mode switching based on type filter

- [ ] **Step 1: Add ImageGridView import and mode switching logic**

In `lib/screens/home_screen.dart`:

1. Add import:
```dart
import '../widgets/image_grid_view.dart';
```

2. In the `Consumer<ClipboardProvider>` builder, after the empty state checks and before the `SliverMainAxisGroup`, add logic to switch to grid mode when type filter is `image`:

Replace the content sliver section. The key change: when `provider.activeTypeFilter == ContentType.image`, use `SliverFillRemaining` with `ImageGridView` instead of `SliverList`:

```dart
                        // Image grid mode
                        if (provider.activeTypeFilter == ContentType.image) {
                          return SliverFillRemaining(
                            child: ImageGridView(entries: history),
                          );
                        }

                        // List mode (text / all)
                        return SliverMainAxisGroup(
                          slivers: [
                            if (provider.hasActiveFilters)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                  child: Text(
                                    '${history.length} 条结果',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  // ... existing ClipboardItem builder
                                },
                                childCount: history.length,
                              ),
                            ),
                          ],
                        );
```

- [ ] **Step 2: Run flutter analyze**

Run: `flutter analyze lib/screens/home_screen.dart`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add lib/screens/home_screen.dart
git commit -m "feat: wire up display mode switching (list vs grid)"
```

---

### Task 8: Full Integration Test & Polish

**Files:**
- Modify: `lib/screens/home_screen.dart` (minor polish)
- Test: `test/widget_test.dart` (existing smoke test)

**Interfaces:**
- All components integrated end-to-end

- [ ] **Step 1: Run full test suite**

Run: `flutter test`
Expected: All tests pass

- [ ] **Step 2: Run flutter analyze**

Run: `flutter analyze`
Expected: No errors

- [ ] **Step 3: Manual verification checklist**

Run `flutter run -d macos` and verify:
- [ ] Search bar appears below AppBar
- [ ] Typing filters history in real-time
- [ ] Type dropdown shows text unlocked, image/file locked
- [ ] Device filter bottom sheet shows available devices
- [ ] "X 条结果" appears when filters active
- [ ] "没有找到匹配的记录" appears when no matches
- [ ] Clear button resets all filters
- [ ] Long text shows "展开 ▼" button, click expands
- [ ] Search query is highlighted in results
- [ ] Merge mode hides search bar
- [ ] Search mode hides merge bar
- [ ] FAB trash button still visible
- [ ] Image grid shows empty state when type=image selected

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: polish and integration fixes for v1.2 search"
```

---

### Task 9: Update Version Roadmap

**Files:**
- Modify: `docs/version-roadmap.md`

- [ ] **Step 1: Mark completed items**

Update v1.2 section:
- 历史记录搜索: ✅
- 条目内容预览优化: ✅

- [ ] **Step 2: Commit**

```bash
git add docs/version-roadmap.md
git commit -m "docs: mark v1.2 search and preview items as complete"
```
