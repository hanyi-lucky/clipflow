# 历史记录搜索与预览优化设计

> 日期：2026-08-01
> 版本：v1.2
> 状态：待审核

---

## 1. 目标

为 ClipFlow 添加历史记录搜索、筛选和预览优化功能，提升日常使用体验。设计需考虑 v1.3（图片同步）和 v1.4（文件同步）的扩展性。

### 核心需求

- 按关键词搜索历史记录（模糊匹配、不区分大小写）
- 按内容类型筛选（文本/图片/文件）
- 按来源设备筛选
- 长文本可展开/折叠
- 图片类型切换为网格大图浏览模式（v1.3 生效）
- 跨平台美观（Windows、Android、macOS、iOS/iPad）

---

## 2. 架构方案

采用 **方案 A：Provider 层管理搜索状态**。

### 数据流

```
UI（SearchBar + 筛选器）
  ↓ 设置 query / filters
ClipboardProvider（持有 _searchQuery、_activeTypeFilter、_activeDeviceFilter）
  ↓ filteredHistory getter
HistoryService（原始数据，不感知搜索）
```

### 职责划分

| 层 | 职责 |
|---|------|
| HistoryService | 原始数据存储、去重、排序、裁剪。不感知搜索 |
| ClipboardProvider | 搜索/筛选状态管理，`filteredHistory` 计算，暴露 `setSearchQuery()`/`setTypeFilter()`/`setDeviceFilter()`/`clearFilters()` |
| UI | 搜索栏输入、筛选器交互、结果展示 |

### 扩展路径

- v1.3 图片：类型筛选解除置灰，`filteredHistory` 中 `ContentType.image` 不参与关键词匹配
- v1.4 文件：类型筛选解除置灰，`filteredHistory` 中 `ContentType.file` 按 `fileName` 匹配
- 全局搜索：Provider 层已就位，扩展 `filteredHistory` 的数据源即可

---

## 3. UI 设计

### 3.1 主页布局

```
┌─────────────────────────────┐
│  ClipFlow              ⚙️  │  ← SliverAppBar
├─────────────────────────────┤
│  🔍 搜索历史...  ▼全部 ⏻筛选 │  ← SearchBar（固定在 AppBar 下方）
├─────────────────────────────┤
│  📋 你好世界              📌│
│  📋 https://example.com     │
│  🖼️ [小缩略图] ...          │  ← 主内容区（列表/网格）
│  📋 一段代码...              │
│  ...                        │
│                        🗑️ │  ← 垃圾箱 FAB（保留原位）
├─────────────────────────────┤
│  [MergeBar 拼接模式]        │  ← 合并模式时显示
└─────────────────────────────┘
```

### 3.2 SearchBar 组件

位置：SliverAppBar 下方，主内容区上方，始终可见。

结构：
- 左侧：搜索图标 + 输入框（placeholder: "搜索历史..."）
- 中间：类型筛选下拉（`▼全部`）
  - 全部
  - 文本
  - 图片 🔒（v1.3 解除置灰）
  - 文件 🔒（v1.4 解除置灰）
- 右侧：筛选按钮（`⏻`）→ 弹出设备筛选 bottom sheet
- 输入内容后右侧出现清除按钮（`✕`）

### 3.3 设备筛选面板

点击 `⏻` 后从底部弹出 bottom sheet：

```
┌─────────────────────────────┐
│  筛选设备                    │
├─────────────────────────────┤
│  ● 全部设备                  │
│  ○ MacBook Pro              │
│  ○ Pixel 7                  │
│  ○ 台式机                    │
└─────────────────────────────┘
```

选项动态来源于当前 history 中出现过的 `sourceDeviceName`，去重后按首次出现顺序排列。

### 3.4 展示模式切换

根据 `_activeTypeFilter` 自动切换：

| 筛选状态 | 展示模式 | 组件 | 说明 |
|---------|---------|------|------|
| 全部 / 仅文本 | 列表模式 | `ClipboardItem` | 现有组件，增加展开/折叠 |
| 仅图片 | 网格模式 | `ImageGridView` | 新建，v1.3 生效 |
| 仅文件 | 列表模式 | `FileListItem` | 新建，v1.4 生效 |

### 3.5 ClipboardItem 预览优化

当前：固定 3 行截断，无法查看完整内容。

改为：
- 默认显示最多 3 行
- 超过 3 行时底部显示"展开"按钮（淡灰色文字）
- 点击展开显示全部内容，按钮变为"折叠"
- 展开/折叠状态不持久化，仅当次浏览有效

### 3.6 ImageGridView（网格模式，v1.3 生效）

- `SliverGrid`，2 列布局，正方形单元格
- 每格：缩略图（cover 模式裁切）+ 底部半透明时间标签（绝对时间，如"12:13"）
- 点击格子 → 全屏 Dialog：大图预览 + 底部"复制"按钮
- 置顶条目左上角显示置顶标记
- v1.2 实现时仅搭框架（空状态提示"图片同步将在 v1.3 支持"），v1.3 填充实际逻辑

### 3.7 搜索结果高亮

- 列表模式：匹配文本用黄色背景高亮包裹
- 网格模式：不高亮（图片无匹配文本）
- 无搜索关键词时不高亮

### 3.8 搜索/合并模式互斥

- 进入搜索模式（输入框有内容或有筛选）时，MergeBar 隐藏
- 进入合并模式时，SearchBar 收起（但保留搜索状态，退出合并后恢复）
- 两者不会同时激活

### 3.9 搜索状态指示

- 有搜索词或有筛选条件时，列表上方显示"X 条结果"提示
- 搜索结果为空时显示空状态提示："没有找到匹配的记录"
- 搜索词和筛选条件可同时生效（AND 关系）

---

## 4. Provider 层变更

### ClipboardProvider 新增状态

```dart
String _searchQuery = '';
ContentType? _activeTypeFilter;
String? _activeDeviceFilter;
```

### filteredHistory getter

```dart
List<ClipboardEntry> get filteredHistory {
  var results = _historyService.entries;

  // 类型筛选
  if (_activeTypeFilter != null) {
    results = results.where((e) => e.type == _activeTypeFilter).toList();
  }

  // 设备筛选
  if (_activeDeviceFilter != null) {
    results = results.where((e) => e.sourceDeviceName == _activeDeviceFilter).toList();
  }

  // 关键词搜索（模糊、不区分大小写）
  if (_searchQuery.isNotEmpty) {
    final query = _searchQuery.toLowerCase();
    results = results.where((e) {
      switch (e.type) {
        case ContentType.text:
          return e.content.toLowerCase().contains(query);
        case ContentType.image:
          return false;  // 图片不参与关键词匹配
        case ContentType.file:
          return false;  // v1.4: 按 fileName 匹配
      }
    }).toList();
  }

  return results;
}
```

### 新增方法

```dart
void setSearchQuery(String query);
void setTypeFilter(ContentType? type);
void setDeviceFilter(String? device);
void clearFilters();  // 重置所有搜索/筛选状态
```

### 可用设备列表 getter

```dart
List<String> get availableDevices {
  return _historyService.entries
    .map((e) => e.sourceDeviceName)
    .toSet()
    .toList();  // 保持首次出现顺序
}
```

---

## 5. 交互细节

### 搜索状态生命周期

| 事件 | 行为 |
|------|------|
| 搜索框为空 + 无筛选 | 显示全量历史（和现在一样） |
| 有搜索词或有筛选 | 显示过滤结果，列表上方显示"X 条结果" |
| 切换密码/重新登录 | 清空搜索状态 |
| App 从后台恢复 | 保持搜索状态 |
| 进入合并模式 | SearchBar 收起，保留搜索状态 |
| 退出合并模式 | SearchBar 恢复之前的搜索状态 |

### 性能

- 当前全量加载最多 200 条到内存，搜索是纯内存遍历，无需防抖
- 如果未来 history 上限提升到 500+，可加 300ms debounce

### 合并模式兼容

- 搜索/筛选状态下可进入合并模式
- `_selectedIds` 不受筛选影响（选中的条目被筛掉仍保留在选中列表）
- 复制拼接内容时按 `_selectedIds` 顺序拼接

---

## 6. 跨平台适配

- 使用 Material Design 3 组件，自动适配各平台风格
- SearchBar 和 Grid 在不同屏幕宽度下自适应（手机 2 列，平板/桌面 3-4 列）
- Bottom sheet 在 iOS/iPad 上使用 `showModalBottomSheet`，原生体验一致
- 搜索高亮颜色使用 Theme 的 `colorScheme`，适配深色/浅色主题

---

## 7. 文件变更预估

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `lib/providers/clipboard_provider.dart` | 修改 | 新增搜索状态、filteredHistory、setSearchQuery 等方法 |
| `lib/screens/home_screen.dart` | 修改 | 集成 SearchBar，根据类型切换列表/网格布局 |
| `lib/widgets/clipboard_item.dart` | 修改 | 预览展开/折叠，搜索高亮 |
| `lib/widgets/search_bar.dart` | 新建 | 搜索栏组件 |
| `lib/widgets/filter_sheet.dart` | 新建 | 设备筛选 bottom sheet |
| `lib/widgets/image_grid_view.dart` | 新建 | 图片网格视图（v1.2 框架，v1.3 填充） |

---

## 8. 不在范围内

- 服务端搜索（服务端存密文，无法搜索）
- 分页加载（当前 200 条内存搜索无性能问题）
- OCR 图片内容搜索（v1.3 不包含）
- 全局搜索（本次仅历史记录，架构预留）
- 搜索历史记录（记录用户搜过什么）
