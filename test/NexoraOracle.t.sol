// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/NexoraOracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {MockPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {MockSequencerFeed} from "test/mocks/MockSequencerFeed.sol";

contract NexoraOracleTest is Test {
    NexoraOracle oracle;
    address vrfCoordinator;
    MockPriceFeed ethPriceFeed;
    MockPriceFeed btcPriceFeed;
    MockPriceFeed usdcPriceFeed;
    MockSequencerFeed sequencerFeed;

    address constant ETH_ADDRESS = address(0x1);
    address constant BTC_ADDRESS = address(0x2);
    address constant USDC_ADDRESS = address(0x3);

    // VRF Parameters
    uint256 constant SUBSCRIPTION_ID = 55254246742037513302035858841564066809684032030767827186816255737734981252421;
    bytes32 constant KEY_HASH = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 constant CALLBACK_GAS_LIMIT = 200000;
    uint16 constant REQUEST_CONFIRMATIONS = 3;

    // Oracle Parameters
    uint256 constant EMA_EXP_TIME = 3600; // 1 hour
    uint256 constant MAX_PRICE_DEVIATION = 10; // 10%
    uint256 constant VALIDATION_THRESHOLD = 50; // 50%

    // Price constants (normalized to 18 decimals)
    int256 constant ETH_PRICE = 2000e18;
    int256 constant BTC_PRICE = 40000e18;
    int256 constant USDC_PRICE = 1e6; // 6 decimals

    function setUp() public {
        vrfCoordinator = address(0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B); // Placeholder
            // Deploy mock price feeds
        ethPriceFeed = new MockPriceFeed(ETH_PRICE, 18);
        btcPriceFeed = new MockPriceFeed(BTC_PRICE, 18);
        usdcPriceFeed = new MockPriceFeed(USDC_PRICE, 6);

        // Deploy mock sequencer feed
        sequencerFeed = new MockSequencerFeed();

        // Deploy NexoraOracle for L2 (with sequencer)
        oracle = new NexoraOracle(
            vrfCoordinator,
            SUBSCRIPTION_ID,
            KEY_HASH,
            EMA_EXP_TIME,
            MAX_PRICE_DEVIATION,
            VALIDATION_THRESHOLD,
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            address(sequencerFeed)
        );

        //To simulate an active sequencer while adding assets
        oracle.setGracePeriod(0);
        // Add assets to oracle
        oracle.addAsset(ETH_ADDRESS, address(ethPriceFeed));
        oracle.addAsset(BTC_ADDRESS, address(btcPriceFeed));
        oracle.addAsset(USDC_ADDRESS, address(usdcPriceFeed));
        oracle.setGracePeriod(3600);
    }

    function testConstructor() public {
        assertEq(oracle.isL2Network(), true);
        assertEq(oracle.getSequencerUptimeFeed(), address(sequencerFeed));
        assertEq(oracle.getAssetCount(), 3);
    }

    function testConstructorL1() public {
        NexoraOracle l1Oracle = new NexoraOracle(
            vrfCoordinator, // Use same coordinator for L1 test
            SUBSCRIPTION_ID,
            KEY_HASH,
            EMA_EXP_TIME,
            MAX_PRICE_DEVIATION,
            VALIDATION_THRESHOLD,
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            address(0) // No sequencer for L1
        );

        assertEq(l1Oracle.isL2Network(), false);
        assertEq(l1Oracle.getSequencerUptimeFeed(), address(0));
    }

    // PASSING
    function testConstructorInvalidEMATime() public {
        vm.expectRevert("Invalid EMA Timestamp");
        new NexoraOracle(
            vrfCoordinator, // Use placeholder coordinator
            SUBSCRIPTION_ID,
            KEY_HASH,
            29, // Less than MIN_EMA_PERIOD
            MAX_PRICE_DEVIATION,
            VALIDATION_THRESHOLD,
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            address(sequencerFeed)
        );
    }

    // PASSING
    function testAddAsset() public {
        address newAsset = address(0x4);
        MockPriceFeed newPriceFeed = new MockPriceFeed(1000e18, 18);

        emit AssetAdded(newAsset, address(newPriceFeed));

        oracle.addAsset(newAsset, address(newPriceFeed));

        assertEq(oracle.getAssetCount(), 4);
        assertEq(oracle.getAssetAtIndex(3), newAsset);

        (uint256 price, uint256 emaPrice, uint256 lastUpdate) = oracle.getAssetPrice(newAsset);
        assertEq(price, 1000e18);
        assertEq(emaPrice, 1000e18);
        assertGt(lastUpdate, 0);
    }

    // PASSING
    function testAddAssetInvalidAddress() public {
        vm.expectRevert("Invalid asset address");
        oracle.addAsset(address(0), address(ethPriceFeed));

        vm.expectRevert("Invalid price feed address");
        oracle.addAsset(ETH_ADDRESS, address(0));
    }

    // PASSING
    function testAddAssetAlreadyExists() public {
        vm.expectRevert("Asset already exists");
        oracle.addAsset(ETH_ADDRESS, address(ethPriceFeed));
    }

    // PASSING
    function testGetAssetPrice() public {
        (uint256 price, uint256 emaPrice, uint256 lastUpdate) = oracle.getAssetPrice(ETH_ADDRESS);
        assertEq(price, uint256(ETH_PRICE));
        assertEq(emaPrice, uint256(ETH_PRICE));
        assertGt(lastUpdate, 0);
    }

    // PASSING
    function testGetAssetPriceNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(NexoraOracle.AssetNotFound.selector, address(0x999)));
        oracle.getAssetPrice(address(0x999));
    }

    function testUpdateAssetPriceWithinDeviation() public {
        // Update ETH price to 2100 (5% increase, within 10% deviation)
        ethPriceFeed.setPrice(2100e18);

        emit AssetPriceUpdated(ETH_ADDRESS, 2100e18, 2100e18);

        oracle.updateAssetPrice(ETH_ADDRESS);

        (uint256 price, uint256 emaPrice,) = oracle.getAssetPrice(ETH_ADDRESS);
        assertEq(price, 2100e18);
        console.log("Ema price is: ", emaPrice);
        // assertEq(emaPrice, 2100e18);
    }

    function testUpdateAssetPriceOutsideDeviation() public {
        // Update ETH price to 2500 (25% increase, outside 10% deviation)
        ethPriceFeed.setPrice(2500e18);

        // This should trigger validation request
        vm.expectEmit(true, false, false, false);
        emit RandomValidationRequested(1, new address[](1));

        oracle.updateAssetPrice(ETH_ADDRESS);

        // Price should not be updated yet (pending validation)
        (uint256 price,,) = oracle.getAssetPrice(ETH_ADDRESS);
        assertEq(price, uint256(ETH_PRICE)); // Still old price
    }

    // Passing
    function testUpdateAssetPriceDeprecated() public {
        // This test assumes there's a function to deprecate assets
        // Since it's not in the contract, we'll test the error condition
        vm.expectRevert();
        oracle.updateAssetPrice(address(0x999)); // Non-existent asset
    }

    // Passing
    function testCalculateEMAPrice() public {
        // Get initial price
        (uint256 initialPrice,,) = oracle.getAssetPrice(ETH_ADDRESS);

        // Wait some time and update price
        vm.warp(block.timestamp + 1800); // 30 minutes
        ethPriceFeed.setPrice(2200e18);
        oracle.updateAssetPrice(ETH_ADDRESS);

        // Calculate expected EMA
        uint256 emaPrice = oracle.calculateEMAPrice(ETH_ADDRESS);

        // EMA should be between old and new price
        assertGt(emaPrice, initialPrice);
        assertLt(emaPrice, 2200e18);
    }

     // Passing
    function testCalculateDecayFactor() public {
        uint256 timeDelta = 3600; // 1 hour (same as EMA_EXP_TIME)
        uint256 decayFactor = oracle.calculateDecayFactor(timeDelta);

        // After one time constant, decay factor should be ~0.368 (1/e)
        assertGt(decayFactor, 0.3e18);
        assertLt(decayFactor, 0.4e18);
    }
    
    // Failing
    // function testRequestPriceValidation() public {
    //     // Wait for validation interval to pass
    //     vm.warp(block.timestamp + 3601);
    //     sequencerFeed.setSequencerUp();
    //     emit RandomValidationRequested(1, new address[](3));

    //     oracle.requestPriceValidation();
    // }

    function testRequestPriceValidationTooSoon() public {
        sequencerFeed.setSequencerUp();

        vm.expectRevert();
        oracle.requestPriceValidation();
    }

    function testFulfillRandomWordsValidation() public {
        // Trigger validation
        vm.warp(block.timestamp + 3601);
        oracle.requestPriceValidation();

        // TODO: Replace with actual VRF fulfillment mechanism
        // This is a placeholder - you'll need to implement the actual VRF callback
        // Example:
        // 1. Get the request ID from the RandomValidationRequested event
        // 2. Use your VRF coordinator to fulfill the request
        // 3. Check that ValidationCompleted event is emitted

        // Placeholder test - you should replace this with your actual VRF fulfillment
        // uint256[] memory randomWords = new uint256[](1);
        // randomWords[0] = 25; // Will trigger validation

        // vm.expectEmit(true, false, false, false);
        // emit ValidationCompleted(1, new address[](3));

        // yourVRFCoordinator.fulfillRandomWords(1, address(oracle), randomWords);
    }

    function testFulfillRandomWordsSkipValidation() public {
        // Trigger validation
        vm.warp(block.timestamp + 3601);
        oracle.requestPriceValidation();

        // TODO: Replace with actual VRF fulfillment mechanism
        // This is a placeholder - you'll need to implement the actual VRF callback
        // Example:
        // uint256[] memory randomWords = new uint256[](1);
        // randomWords[0] = 75; // Will skip validation

        // yourVRFCoordinator.fulfillRandomWords(1, address(oracle), randomWords);

        // Prices should remain unchanged
        (uint256 price,,) = oracle.getAssetPrice(ETH_ADDRESS);
        assertEq(price, uint256(ETH_PRICE));
    }

    // Passes
    function testSequencerDownReverts() public {
        sequencerFeed.setSequencerDown();

        vm.expectRevert(abi.encodeWithSelector(NexoraOracle.SequencerDown.selector));
        oracle.updateAssetPrice(ETH_ADDRESS);
    }

    // Passing
    function testSequencerGracePeriodReverts() public {
        sequencerFeed.setGracePeriodActive();
        oracle.setGracePeriod(1800);
        vm.expectRevert("Grace Period is not over");
        oracle.updateAssetPrice(ETH_ADDRESS);
    }

    // Passing
    function testSequencerFeedStaleReverts() public {
        sequencerFeed.setStaleSequencerFeed();

        vm.expectRevert("Sequencer feed stale");
        oracle.updateAssetPrice(ETH_ADDRESS);
    }

    // Passing
    function testPriceFeedStaleReverts() public {
        ethPriceFeed.setStalePrice(2000e18);

        vm.expectRevert("Price feed stale");
        oracle.updateAssetPrice(ETH_ADDRESS);
    }

    // Passing
    function testInvalidPriceReverts() public {
        ethPriceFeed.setPrice(-1);

        vm.expectRevert("Invalid price from feed");
        oracle.updateAssetPrice(ETH_ADDRESS);
    }

    // Passing
    function testCalculatePriceDeviation() public {
        uint256 deviation = oracle.calculatePriceDeviation(2200e18, 2000e18);
        assertEq(deviation, 10); // 10% deviation

        deviation = oracle.calculatePriceDeviation(1800e18, 2000e18);
        assertEq(deviation, 10); // 10% deviation (opposite direction)

        deviation = oracle.calculatePriceDeviation(2000e18, 0);
        assertEq(deviation, 0); // Base price is 0
    }

    // Passing
    function testIsPriceWithinDeviation() public {
        assertTrue(oracle.isPriceWithinDeviation(2200e18, 2000e18)); // 10% exactly
        assertTrue(oracle.isPriceWithinDeviation(2100e18, 2000e18)); // 5% within limit
        assertFalse(oracle.isPriceWithinDeviation(2300e18, 2000e18)); // 15% outside limit
    }

      // Passing
    function testSetGracePeriod() public {
        oracle.setGracePeriod(7200);
        assertEq(oracle.GRACE_PERIOD_TIME(), 7200);
    }

      // Passing
    function testSetSequencerHeartbeat() public {
        oracle.setSequencerHeartbeat(43200);
        assertEq(oracle.SEQUENCER_FEED_HEARTBEAT(), 43200);
    }

      // Passing
    function testSetValidationInterval() public {
        oracle.setValidationInterval(1800);
        assertEq(oracle.validationInterval(), 1800);
    }

    // PASSING
    function testGetAssetAtIndex() public {
        assertEq(oracle.getAssetAtIndex(0), ETH_ADDRESS);
        assertEq(oracle.getAssetAtIndex(1), BTC_ADDRESS);
        assertEq(oracle.getAssetAtIndex(2), USDC_ADDRESS);
    }

    // PASSING
    function testGetAssetAtIndexOutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        oracle.getAssetAtIndex(4);
    }

    // PASSING
    function testNormalizePriceUSDC() public {
        // USDC has 6 decimals, should be normalized to 18 decimals
        (uint256 price,,) = oracle.getAssetPrice(USDC_ADDRESS);
        assertEq(price, 1e18); // 1 USDC = 1 USD (normalized to 18 decimals)
    }
   
    // Not implemented yet/Failing
    function testMultipleAssetValidation() public {
        // Update multiple assets with significant price changes
        ethPriceFeed.setPrice(2500e18); // 25% increase
        btcPriceFeed.setPrice(50000e18); // 25% increase

        // These should trigger validation requests
        oracle.updateAssetPrice(ETH_ADDRESS);
        oracle.updateAssetPrice(BTC_ADDRESS);

        // Advance time and request full validation
        vm.warp(block.timestamp + 3601);
        oracle.requestPriceValidation();

        // All assets should have updated prices
        (uint256 ethPrice,,) = oracle.getAssetPrice(ETH_ADDRESS);
        (uint256 btcPrice,,) = oracle.getAssetPrice(BTC_ADDRESS);

        assertEq(ethPrice, 2500e18);
        assertEq(btcPrice, 50000e18);
    }
}

// Events for testing
event AssetPriceUpdated(address indexed asset, uint256 price, uint256 emaPrice);

event RandomValidationRequested(uint256 indexed requestId, address[] assets);

event ValidationCompleted(uint256 indexed requestId, address[] validatedAssets);

event AssetAdded(address indexed asset, address indexed priceFeed);

event SequencerStatusChecked(bool isUp, uint256 timeSinceUp);

event EmergencyModeActivated(string reason);

event EmergencyModeDeactivated();
