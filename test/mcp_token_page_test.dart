import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pfm/api/fm_repository.dart';
import 'package:pfm/l10n/app_localizations.dart';
import 'package:pfm/pages/settings/mcp_token_page.dart';
import 'package:pfm_proto/native/mcp.pb.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

/// MCP 令牌页：三个接口用替身注入，验证列表 / 空态 / 失败态 / 签发表单与一次性明文。
Widget _wrap({
  required McpTokenListFn list,
  McpTokenCreateFn? create,
}) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: McpTokenPage(listTokens: list, createToken: create),
  );
}

Future<ApiResult<ListMcpTokensResp>> _listOf(List<McpTokenInfo> tokens) async {
  return ApiResult<ListMcpTokensResp>(
    success: true,
    data: ListMcpTokensResp(tokens: tokens),
  );
}

McpTokenInfo _token({
  required String name,
  bool allowWrite = false,
  String rootFolderPath = '',
  bool expired = false,
  int expiresInDays = 0,
}) {
  final info = McpTokenInfo(name: name, allowRead: true, allowWrite: allowWrite);
  if (rootFolderPath.isNotEmpty) {
    info.rootFolderId = 'folder-1';
    info.rootFolderPath = rootFolderPath;
  }
  if (expiresInDays > 0) {
    final now = DateTime.now();
    info.expiresAt = Timestamp.fromDateTime(
      now.add(Duration(days: expiresInDays)).toUtc(),
    );
  }
  info.expired = expired;
  return info;
}

void main() {
  testWidgets('真实响应报文能直接渲染（字段名以 protojson 为准）', (tester) async {
    // 下面这段取自真实实例 /api/mcp/token/list 的 data（去掉 @type 外壳），
    // 用来钉住字段名：页面读的是 camelCase，与宿主 protojson 输出一致。
    const raw = '{"tokens":[{"id":1,"name":"cursor",'
        '"ownerId":"u-1","ownerName":"tester","allowRead":true,'
        '"allowWrite":false,"rootFolderId":"","expired":false,'
        '"createdAt":"2026-10-31T02:00:53.952654135Z"}]}';
    final resp = ListMcpTokensResp()
      ..mergeFromProto3Json(jsonDecode(raw) as Map<String, dynamic>);

    await tester.pumpWidget(
      _wrap(list: () => _listOf(resp.tokens)),
    );
    await tester.pumpAndSettle();

    expect(find.text('cursor'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('可见范围: 整棵树'), findsOneWidget);
  });

  testWidgets('没有令牌时给出空态与签发入口', (tester) async {
    await tester.pumpWidget(_wrap(list: () => _listOf(const [])));
    await tester.pumpAndSettle();

    expect(find.text('还没有 MCP 令牌'), findsOneWidget);
    expect(find.textContaining('签发后把地址与令牌填进'), findsOneWidget);
    expect(find.text('签发令牌'), findsWidgets);
  });

  testWidgets('列表展示名称、权限、可见范围与过期状态', (tester) async {
    await tester.pumpWidget(
      _wrap(
        list: () => _listOf([
          _token(name: 'laptop', rootFolderPath: '/工作'),
          _token(name: 'cursor', allowWrite: true, expired: true),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('laptop'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('可见范围: /工作'), findsOneWidget);
    expect(find.text('cursor'), findsOneWidget);
    expect(find.text('读写'), findsOneWidget);
    expect(find.text('可见范围: 整棵树'), findsOneWidget);
    expect(find.text('已过期'), findsOneWidget);
    expect(find.text('从未使用'), findsNWidgets(2));
  });

  testWidgets('加载失败显示错误文案与重试', (tester) async {
    await tester.pumpWidget(
      _wrap(
        list: () async =>
            ApiResult<ListMcpTokensResp>(success: false, message: '网络不可达'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('网络不可达'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('签发时名称必填', (tester) async {
    var createCalled = false;
    await tester.pumpWidget(
      _wrap(
        list: () => _listOf(const []),
        create: (draft) async {
          createCalled = true;
          return ApiResult<CreateMcpTokenResp>(success: true);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '签发令牌'));
    await tester.pumpAndSettle();
    expect(find.text('签发 MCP 令牌'), findsOneWidget);

    // 不填名称直接提交：留在表单里提示，不发请求
    await tester.tap(find.widgetWithText(FilledButton, '签发令牌').last);
    await tester.pumpAndSettle();

    expect(find.text('请填写名称'), findsOneWidget);
    expect(createCalled, isFalse);
  });

  testWidgets('签发成功后弹出一次性明文与客户端配置', (tester) async {
    await tester.pumpWidget(
      _wrap(
        list: () => _listOf(const []),
        create: (draft) async => ApiResult<CreateMcpTokenResp>(
          success: true,
          data: CreateMcpTokenResp(
            token: McpTokenInfo(name: draft.name, allowRead: true),
            plaintext: 'pfm_mcp_abc123',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '签发令牌'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'cursor');
    await tester.tap(find.widgetWithText(FilledButton, '签发令牌').last);
    await tester.pumpAndSettle();

    expect(find.text('pfm_mcp_abc123'), findsOneWidget);
    expect(find.textContaining('Bearer pfm_mcp_abc123'), findsOneWidget);
    expect(find.textContaining('令牌仅显示这一次'), findsOneWidget);
    expect(find.text('复制配置'), findsOneWidget);
  });
}
