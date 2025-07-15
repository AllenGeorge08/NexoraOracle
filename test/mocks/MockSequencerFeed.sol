// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";

contract MockSequencerFeed is AggregatorV2V3Interface {
    int256 private _answer; // 0 = up, 1 = down
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor() {
        _answer = 0; // Sequencer is up by default
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "Mock Sequencer Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (roundId, _answer, _startedAt, _updatedAt, roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }

    function latestAnswer() external view override returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view override returns (uint256) {
        return _updatedAt;
    }

    function latestRound() external view override returns (uint256) {
        return _roundId;
    }

    function getAnswer(uint256 roundId) external view override returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256 roundId) external view override returns (uint256) {
        return _updatedAt;
    }

    // Helper functions for testing
    function setSequencerDown() external {
        _answer = 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setSequencerUp() external {
        _answer = 0;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setStaleSequencerFeed() external {
        _updatedAt = block.timestamp - 90000; // More than 24 hours ago
    }

    function setGracePeriodActive() external {
        _answer = 0;
        _startedAt = block.timestamp - 3600; // 60 minutes ago (within grace period)
        _updatedAt = block.timestamp;
        _roundId++;
    }
}
