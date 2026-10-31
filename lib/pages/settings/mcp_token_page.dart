import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pfm/api/fm_repository.dart';
import 'package:pfm/design/design_tokens.dart';
import 'package:pfm/l10n/app_localizations.dart';
import 'package:pfm/pages/files/folder_picker_page.dart';
import 'package:pfm_proto/native/mcp.pb.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

/// 列表接口（测试可注入替身）
typedef McpTokenListFn = Future<ApiResult<ListMcpTokensResp>> Function();

/// 签发接口
typedef McpTokenCreateFn = Future<ApiResult<CreateMcpTokenResp>> Function(
  McpTokenDraft draft,
);

/// 撤销接口
typedef McpTokenRevokeFn = Future<ApiResult<void>> Function(int id);

/// 签发表单的结果
class McpTokenDraft {
  final String name;
  final bool allowWrite;
  final String rootFolderId;
  final int expiresInDays;

  const McpTokenDraft({
    required this.name,
    required this.allowWrite,
    required this.rootFolderId,
    required this.expiresInDays,
  });
}

/// MCP 令牌管理页
///
/// 每个令牌 = 一个客户端标签 + 只读/读写 + 可选的可见根目录 + 可选有效期。
/// AI 客户端（Cursor / Claude 等）用该令牌访问 `/mcp`，看得见的 "/" 就是
/// 授权目录，路径与 file_id 都出不去。
/// 令牌明文只在签发那一次由服务端返回，之后不可再查看（库里只有 sha256）。
class McpTokenPage extends StatefulWidget {
  const McpTokenPage({
    super.key,
    this.listTokens,
    this.createToken,
    this.revokeToken,
  });

  /// 以下三个回调只用于测试注入；为 null 时走 [FmRepository]
  final McpTokenListFn? listTokens;
  final McpTokenCreateFn? createToken;
  final McpTokenRevokeFn? revokeToken;

  @override
  State<McpTokenPage> createState() => _McpTokenPageState();
}

class _McpTokenPageState extends State<McpTokenPage> {
  /// 懒建：注入替身时不会碰 GetIt / Dio
  FmRepository? _repoInstance;
  FmRepository get _repo => _repoInstance ??= FmRepository();

  Future<ApiResult<ListMcpTokensResp>> _list() {
    final fn = widget.listTokens;
    return fn != null ? fn() : _repo.listMcpTokens();
  }

  Future<ApiResult<CreateMcpTokenResp>> _createToken(McpTokenDraft draft) {
    final fn = widget.createToken;
    if (fn != null) return fn(draft);
    return _repo.createMcpToken(
      name: draft.name,
      allowWrite: draft.allowWrite,
      rootFolderId: draft.rootFolderId,
      expiresInDays: draft.expiresInDays,
    );
  }

  Future<ApiResult<void>> _revokeToken(int id) {
    final fn = widget.revokeToken;
    return fn != null ? fn(id) : _repo.revokeMcpToken(id: id);
  }

  bool _loading = true;
  String? _error;
  List<McpTokenInfo> _tokens = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _list();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.success && result.data != null) {
        _tokens = result.data!.tokens;
      } else {
        _error =
            result.message ?? AppLocalizations.of(context).mcpToken_loadFailed;
      }
    });
  }

  // ---------------- 地址与配置片段 ----------------

  String get _endpoint {
    // 未建真实仓库时（测试注入）退回相对地址
    final base = _repoInstance?.serverBaseUrl ?? '';
    return base.isEmpty ? '/mcp' : '$base/mcp';
  }

  /// 给客户端的配置片段（[token] 为空时用占位符，避免把明文写进常驻 UI）
  String _clientConfig(String token) {
    final secret = token.isEmpty ? '<令牌>' : token;
    return '{\n'
        '  "mcpServers": {\n'
        '    "pfm": {\n'
        '      "url": "$_endpoint",\n'
        '      "headers": { "Authorization": "Bearer $secret" }\n'
        '    }\n'
        '  }\n'
        '}';
  }

  // ---------------- 操作 ----------------

  Future<void> _copy(String text) async {
    final al = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    _toast(al.webdavAccount_copied);
  }

  /// 签发令牌：成功后弹出一次性明文 + 可复制的客户端配置
  Future<void> _create() async {
    final al = AppLocalizations.of(context);
    final draft = await showDialog<McpTokenDraft>(
      context: context,
      builder: (_) => const _McpTokenFormDialog(),
    );
    if (draft == null || !mounted) return;

    final result = await _createToken(draft);
    if (!mounted) return;
    if (!result.success || result.data == null) {
      _toast(result.message ?? al.mcpToken_createFailed);
      return;
    }
    await _load();
    if (!mounted) return;
    await _showPlaintextDialog(result.data!.plaintext);
    _toast(al.mcpToken_created);
  }

  Future<void> _revoke(McpTokenInfo token) async {
    final al = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(al.mcpToken_revoke),
        content: Text(al.mcpToken_revokeConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(al.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(al.common_confirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final result = await _revokeToken(token.id.toInt());
    if (!mounted) return;
    if (!result.success) {
      _toast(result.message ?? al.mcpToken_revokeFailed);
      return;
    }
    await _load();
    _toast(al.mcpToken_revoked);
  }

  /// 展示一次性令牌明文（关闭后无法再查看）
  Future<void> _showPlaintextDialog(String plaintext) async {
    final al = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(al.mcpToken_plaintextLabel),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(al.mcpToken_plaintextOnce),
              const SizedBox(height: PfmSpacing.md),
              _monoBox(ctx, plaintext, 15),
              const SizedBox(height: PfmSpacing.lg),
              Text(al.mcpToken_clientConfig),
              const SizedBox(height: PfmSpacing.xs),
              _monoBox(ctx, _clientConfig(plaintext), 12),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: _clientConfig(plaintext)),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              _toast(al.webdavAccount_copied);
            },
            child: Text(al.mcpToken_copyConfig),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(al.common_close),
          ),
        ],
      ),
    );
  }

  Widget _monoBox(BuildContext ctx, String text, double fontSize) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(PfmSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(al.mcpToken_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: al.mcpToken_add,
            onPressed: _create,
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody(al)),
    );
  }

  Widget _buildBody(AppLocalizations al) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(PfmSpacing.lg),
        children: [
          const SizedBox(height: PfmSpacing.xl),
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: PfmSpacing.md),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: PfmSpacing.md),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(al.common_retry),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(PfmSpacing.lg),
      children: [
        _buildEndpointCard(al),
        const SizedBox(height: PfmSpacing.lg),
        if (_tokens.isEmpty) _buildEmpty(al) else ..._tokens.map(_buildTokenCard),
      ],
    );
  }

  Widget _buildEndpointCard(AppLocalizations al) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(PfmSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link_outlined),
                const SizedBox(width: PfmSpacing.sm),
                Text(
                  al.mcpToken_endpoint,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: PfmSpacing.sm),
            SelectableText(
              _endpoint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: PfmSpacing.sm),
            Text(
              al.mcpToken_endpointHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: PfmSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _copy(_endpoint),
                icon: const Icon(Icons.copy, size: 18),
                label: Text(al.webdavAccount_copy),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(AppLocalizations al) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PfmSpacing.xl),
      child: Column(
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: PfmSpacing.md),
          Text(
            al.mcpToken_empty,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: PfmSpacing.sm),
          Text(
            al.mcpToken_emptyHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: PfmSpacing.lg),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: Text(al.mcpToken_add),
          ),
        ],
      ),
    );
  }

  Widget _buildTokenCard(McpTokenInfo token) {
    final al = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final scope = token.rootFolderPath.isNotEmpty
        ? token.rootFolderPath
        : (token.rootFolderId.isEmpty ? al.mcpToken_scopeAll : token.rootFolderId);
    final lastUsed = token.hasLastUsedAt() && token.lastUsedAt.seconds.toInt() > 0
        ? '${al.mcpToken_lastUsed}: ${_formatTimestamp(token.lastUsedAt)}'
        : al.mcpToken_neverUsed;
    final expires = token.hasExpiresAt() && token.expiresAt.seconds.toInt() > 0
        ? '${al.mcpToken_expires}: ${_formatTimestamp(token.expiresAt)}'
        : '${al.mcpToken_expires}: ${al.mcpToken_neverExpires}';

    return Card(
      margin: const EdgeInsets.only(bottom: PfmSpacing.md),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: PfmSpacing.lg,
          vertical: PfmSpacing.sm,
        ),
        leading: Icon(
          token.allowWrite ? Icons.sync_outlined : Icons.visibility_outlined,
          color: token.expired ? colorScheme.onSurfaceVariant : PfmColors.primary,
        ),
        title: Text(
          token.name.isEmpty ? al.common_unknown : token.name,
          style: token.expired
              ? TextStyle(color: colorScheme.onSurfaceVariant)
              : null,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: PfmSpacing.xs),
            Text('${al.mcpToken_scope}: $scope'),
            Text(expires),
            const SizedBox(height: PfmSpacing.xs),
            Wrap(
              spacing: PfmSpacing.sm,
              runSpacing: PfmSpacing.xs,
              children: [
                _chip(
                  token.allowWrite
                      ? al.mcpToken_readWrite
                      : al.mcpToken_readOnly,
                  colorScheme.primary,
                ),
                if (token.expired) _chip(al.mcpToken_expired, colorScheme.error),
                _chip(lastUsed, colorScheme.onSurfaceVariant),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'revoke') _revoke(token);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'revoke', child: Text(al.mcpToken_revoke)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  String _formatTimestamp(Timestamp ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts.seconds.toInt() * 1000);
    return DateFormat('yyyy-MM-dd HH:mm').format(dt.toLocal());
  }
}

/// 签发令牌表单
class _McpTokenFormDialog extends StatefulWidget {
  const _McpTokenFormDialog();

  @override
  State<_McpTokenFormDialog> createState() => _McpTokenFormDialogState();
}

class _McpTokenFormDialogState extends State<_McpTokenFormDialog> {
  final _nameCtrl = TextEditingController();

  String _rootFolderId = '';
  String _rootPath = '';
  bool _allowWrite = false;
  int _expiresInDays = 0;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await Navigator.of(context).push<FolderPickResult>(
      MaterialPageRoute(
        builder: (_) => FolderPickerPage(initialFolderId: _rootFolderId),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _rootFolderId = picked.id;
      _rootPath = picked.name;
    });
  }

  void _clearFolder() {
    setState(() {
      _rootFolderId = '';
      _rootPath = '';
    });
  }

  void _submit() {
    final al = AppLocalizations.of(context);
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(al.mcpToken_nameRequired)),
      );
      return;
    }
    Navigator.of(context).pop(
      McpTokenDraft(
        name: name,
        allowWrite: _allowWrite,
        rootFolderId: _rootFolderId,
        expiresInDays: _expiresInDays,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    const dayOptions = [0, 7, 30, 90, 365];

    return AlertDialog(
      title: Text(al.mcpToken_createTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              maxLength: 64,
              decoration: InputDecoration(
                labelText: al.mcpToken_nameLabel,
                helperText: al.mcpToken_nameHint,
                counterText: '',
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Text(al.mcpToken_selectFolder),
              subtitle: Text(
                _rootFolderId.isEmpty
                    ? al.mcpToken_scopeAll
                    : (_rootPath.isEmpty ? _rootFolderId : _rootPath),
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_rootFolderId.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: al.mcpToken_clearFolder,
                      onPressed: _clearFolder,
                    ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              onTap: _pickFolder,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowWrite,
              onChanged: (v) => setState(() => _allowWrite = v),
              title: Text(al.mcpToken_allowWriteLabel),
              subtitle: Text(
                al.mcpToken_allowWriteHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text(al.mcpToken_expires),
              trailing: DropdownButton<int>(
                value: _expiresInDays,
                underline: const SizedBox.shrink(),
                onChanged: (v) {
                  if (v != null) setState(() => _expiresInDays = v);
                },
                items: [
                  for (final days in dayOptions)
                    DropdownMenuItem(
                      value: days,
                      child: Text(
                        days == 0
                            ? al.mcpToken_neverExpires
                            : al.mcpToken_expiresInDays(days),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.common_cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(al.mcpToken_add),
        ),
      ],
    );
  }
}
