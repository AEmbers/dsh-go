// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/drawer_view_state.dart';
import '../../common/segmented_pill.dart';

/// 进行中 / 历史, above the status capsules.
class DrawerScopeBar extends ConsumerWidget {
  const DrawerScopeBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(drawerListScopeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: SegmentedPill<DrawerListScope>(
        key: const ValueKey('drawer-list-scope'),
        segments: [for (final value in DrawerListScope.values) PillSegment(value, value.label)],
        selected: scope,
        onChanged: (next) => ref.read(drawerListScopeProvider.notifier).set(next),
      ),
    );
  }
}
