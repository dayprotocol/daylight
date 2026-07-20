// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::leader_activity_log_tests {
    use day::leader_activity_log;

    /// ORDERED is intentionally distinct from the two authenticated spoke
    /// terminal states. The command-derived event fixture lives with the final
    /// hub consumer because only that module can construct the linear command.
    #[test]
    fun test_three_state_join_surface_has_no_outcome_emitter() {
        assert!(leader_activity_log::ordered_state() == 1, 0);
        assert!(leader_activity_log::executed_state() == 2, 1);
        assert!(leader_activity_log::failed_state() == 3, 2);
        leader_activity_log::assert_terminal_outcome_state(
            leader_activity_log::executed_state(),
        );
        leader_activity_log::assert_terminal_outcome_state(
            leader_activity_log::failed_state(),
        );
    }

    #[test, expected_failure(abort_code = leader_activity_log::E_NOT_TERMINAL_STATE)]
    fun test_ordered_is_not_a_terminal_spoke_outcome() {
        leader_activity_log::assert_terminal_outcome_state(
            leader_activity_log::ordered_state(),
        );
    }
}
