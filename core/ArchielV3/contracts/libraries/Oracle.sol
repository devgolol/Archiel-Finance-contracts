// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Oracle
/// @notice Archiel original — a ring buffer of tick observations recorded on
/// every swap, allowing anyone to derive a time-weighted average price (TWAP)
/// over an arbitrary recent window without trusting a single spot price.
library Oracle {
    error O_NotInitialized();

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    function initialize(
        Observation[65535] storage self,
        uint32 time
    ) internal returns (uint16 cardinality, uint16 cardinalityNext) {
        self[0] = Observation({blockTimestamp: time, tickCumulative: 0, initialized: true});
        return (1, 1);
    }

    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

        cardinalityUpdated = (cardinalityNext > cardinality && index == (cardinality - 1))
            ? cardinalityNext
            : cardinality;

        indexUpdated = (index + 1) % cardinalityUpdated;
        uint32 delta = blockTimestamp - last.blockTimestamp;
        self[indexUpdated] = Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(delta)),
            initialized: true
        });
    }

    function grow(
        Observation[65535] storage self,
        uint16 current,
        uint16 next
    ) internal returns (uint16) {
        if (current == 0) revert O_NotInitialized();
        if (next <= current) return current;
        for (uint16 i = current; i < next; i++) {
            self[i].blockTimestamp = 1; // marks slot as allocated, not yet observed
        }
        return next;
    }

    /// @notice Returns the tickCumulative value `secondsAgo` seconds before now,
    /// linearly interpolated between the two surrounding stored observations.
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative) {
        if (secondsAgo == 0) {
            Observation memory last = self[index];
            if (last.blockTimestamp != time) {
                uint32 delta = time - last.blockTimestamp;
                return last.tickCumulative + int56(tick) * int56(uint56(delta));
            }
            return last.tickCumulative;
        }

        uint32 target = time - secondsAgo;
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            _getSurroundingObservations(self, time, target, index, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            return beforeOrAt.tickCumulative;
        } else if (target == atOrAfter.blockTimestamp) {
            return atOrAfter.tickCumulative;
        } else {
            uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;
            return beforeOrAt.tickCumulative +
                ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(uint56(observationTimeDelta)))
                * int56(uint56(targetDelta));
        }
    }

    function _getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        beforeOrAt = self[index];

        if (beforeOrAt.blockTimestamp <= target) {
            if (beforeOrAt.blockTimestamp == target) {
                return (beforeOrAt, beforeOrAt);
            }
            return (beforeOrAt, Observation({blockTimestamp: time, tickCumulative: 0, initialized: false}));
        }

        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        return _binarySearchObservations(self, target, index, cardinality);
    }

    /// @dev Binary search for the two observations bracketing `target`, split
    /// out of _getSurroundingObservations purely to keep that function's
    /// local-variable count low enough to compile without viaIR.
    function _binarySearchObservations(
        Observation[65535] storage self,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        uint256 l = 0;
        uint256 r = cardinality - 1;
        while (true) {
            uint256 i = (l + r) / 2;
            beforeOrAt = self[(index + 1 + i) % cardinality];
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }
            atOrAfter = self[(index + 1 + i + 1) % cardinality];

            bool targetAtOrAfter = beforeOrAt.blockTimestamp <= target;
            if (targetAtOrAfter && target <= atOrAfter.blockTimestamp) break;
            if (!targetAtOrAfter) r = i - 1; else l = i + 1;
        }
    }
}
