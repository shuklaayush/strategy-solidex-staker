from helpers.StrategyCoreResolver import StrategyCoreResolver
from rich.console import Console
from brownie import interface
from tabulate import tabulate
from helpers.utils import val

console = Console()

class StrategyResolver(StrategyCoreResolver):
    def get_strategy_destinations(self):
        """
        Track balances for all strategy implementations
        (Strategy Must Implement)
        """
        strategy = self.manager.strategy
        return {
            "lpDepositor": strategy.lpDepositor(),
            "router": strategy.router(),
            "badgerTree": strategy.badgerTree(),
        }

    def add_balances_snap(self, calls, entities):
        super().add_balances_snap(calls, entities)
        strategy = self.manager.strategy

        solidHelperVault = interface.IERC20(strategy.solidHelperVault())
        sexHelperVault = interface.IERC20(strategy.sexHelperVault())

        calls = self.add_entity_balances_for_tokens(calls, "solidHelperVault", solidHelperVault, entities)
        calls = self.add_entity_balances_for_tokens(calls, "sexHelperVault", sexHelperVault, entities)

        return calls

    def hook_after_confirm_withdraw(self, before, after, params):
        """
        Specifies extra check for ordinary operation on withdrawal
        Use this to verify that balances in the get_strategy_destinations are properly set
        """
        assert True

    def hook_after_confirm_deposit(self, before, after, params):
        """
        Specifies extra check for ordinary operation on deposit
        Use this to verify that balances in the get_strategy_destinations are properly set
        """
        assert True

    def hook_after_earn(self, before, after, params):
        """
        Specifies extra check for ordinary operation on earn
        Use this to verify that balances in the get_strategy_destinations are properly set
        """
        assert True

    def printState(self, event, keys):
        table = []
        nonAmounts = ["token", "destination", "blockNumber", "timestamp"]
        for key in keys:
            if key in nonAmounts:
                table.append([key, event[key]])
            else:
                table.append([key, val(event[key])])

        print(tabulate(table, headers=["account", "value"]))

    def confirm_harvest_events(self, before, after, tx):
        key = "PerformanceFeeGovernance"
        assert key in tx.events
        assert len(tx.events[key]) == 2

        for event in tx.events[key]:
            keys = [
                "destination",
                "token",
                "amount",
                "blockNumber",
                "timestamp",
            ]
            for key in keys:
                assert key in event

            console.print(
                "[blue]== Solidex Strat harvest() PerformanceFeeGovernance State ==[/blue]"
            )
            self.printState(event, keys)

        key = "Harvest"
        assert key in tx.events
        assert len(tx.events[key]) == 1
        event = tx.events[key][0]
        keys = [
            "harvested",
        ]
        for key in keys:
            assert key in event

        console.print("[blue]== Helper Strat harvest() State ==[/blue]")
        self.printState(event, keys)

        key = "PerformanceFeeStrategist"
        assert key not in tx.events
        # Strategist performance fee is set to 0

    def confirm_harvest(self, before, after, tx):
        """
        Verfies that the Harvest produced yield and fees
        """
        console.print("=== Compare Harvest ===")
        super().confirm_harvest(before, after, tx)

        assert after.get("sett.pricePerFullShare") == before.get(
            "sett.pricePerFullShare"
        )

        assert tx.return_value == 0

        self.confirm_harvest_events(before, after, tx)

        for token in ["solidHelperVault", "sexHelperVault"]:
            assert after.balances(token, "badgerTree") > before.balances(
                token, "badgerTree"
            )

            # Strategist should earn if fee is enabled and value was generated
            if before.get("strategy.performanceFeeStrategist") > 0:
                assert after.balances(token, "strategist") > before.balances(
                    token, "strategist"
                )

            # Governance should earn if fee is enabled and value was generated
            if before.get("strategy.performanceFeeGovernance") > 0:
                assert after.balances(token, "governanceRewards") > before.balances(
                    token, "governanceRewards"
                )


    def confirm_tend(self, before, after, tx):
        """
        Tend Should;
        - Increase the number of staked tended tokens in the strategy-specific mechanism
        - Reduce the number of tended tokens in the Strategy to zero

        (Strategy Must Implement)
        """
        assert True

