// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {exp} from "@prb/math/src/sd59x18/Math.sol";
import {SD59x18, sd} from "@prb/math/src/SD59x18.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";

//   _   _ ________   ______  _____               ____  _____            _____ _      ______
//  | \ | |  ____\ \ / / __ \|  __ \     /\      / __ \|  __ \     /\   / ____| |    |  ____|
//  |  \| | |__   \ V / |  | | |__) |   /  \    | |  | | |__) |   /  \ | |    | |    | |__
//  | . ` |  __|   > <| |  | |  _  /   / /\ \   | |  | |  _  /   / /\ \| |    | |    |  __|
//  | |\  | |____ / . \ |__| | | \ \  / ____ \  | |__| | | \ \  / ____ \ |____| |____| |____
//  |_| \_|______/_/ \_\____/|_|  \_\/_/    \_\  \____/|_|  \_\/_/    \_\_____|______|______|

contract NexoraOracle is VRFConsumerBaseV2Plus {
    // ERRORS
    error IsDeprecated(address asset);
    error AssetNotFound(address asset);
    error InvalidRandomness();
    error ValidationFailed(address asset);
    error PriceDeviationTooHigh(address asset, uint256 deviation);
    error SequencerDown();
    error GracePeriodNotOver();
    error SequencerFeedStale();

    // Price tracking
    uint256 public constant MIN_EMA_PERIOD = 30;
    uint256 public constant MAX_EMA_PERIOD = 365 * 86400;
    uint256 public immutable EMA_EXPTime;
    uint256 private maxPriceDeviation;

    // PRECISION
    uint256 PRECISION = 1e18;

    // Booleans
    bool private isInitialized;

    // Chainlink VRF Parameters
    bytes32 keyHash;
    uint256 private subscriptionId;
    uint32 callBackGasLimit;
    uint16 public REQUEST_CONFIRMATIONS;

    // L2 Sequencer Parameters
    AggregatorV2V3Interface public immutable sequencerUptimeFeed;
    uint256 public GRACE_PERIOD_TIME = 3600;
    uint256 public SEQUENCER_FEED_HEARTBEAT = 86400; //q Is this correct
    bool public immutable isL2;

    //Validation parameters
    uint256 public lastValidationTime;
    uint256 public validationInterval = 3600; //1 hour default
    uint256 public validationThreshold;
    uint256 randomSamplingWindow;
    // uint256 public validationInterval= 3600; //1 hour default
    mapping(uint256 => uint256) requestIdToTimestamp;
    mapping(uint256 => address[]) requestIdToAssets; //Tracks which assets are being validated
    mapping(uint256 => mapping(address => uint256)) requestIdToAssetPrice; //Store prices for validation

    // Asset struct
    struct Asset {
        address assetAddress;
        uint256 price;
        uint256 lastVerifiedPrice;
        uint256 lastUpdateTime;
        uint256 emaPrice;
        bool isDeprecated;
        uint256 lastRequestId;
        AggregatorV3Interface priceFeed;
        uint8 decimals;
    }

    // Mappings and arrays
    mapping(address => Asset) assets;
    address[] public assetList;

    // Events
    event AssetPriceUpdated(address indexed asset, uint256 price, uint256 emaPrice);
    event RandomValidationRequested(uint256 indexed requestId, address[] assets);
    event ValidationCompleted(uint256 indexed requestId, address[] validatedAssets);
    event AssetAdded(address indexed asset, address indexed priceFeed);
    event SequencerStatusChecked(bool isUp, uint256 timeSinceUp);
    event EmergencyModeActivated(string reason);
    event EmergencyModeDeactivated();

    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint256 _emaExpTime,
        uint256 _maxPriceDeviation,
        uint256 _validationThreshold,
        uint256 _randomSamplingWindow,
        uint32 _callBackGasLimit,
        uint16 _requestConfirmations,
        address _sequencerUptimeFeed //Pass address(0) for l1 networks
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_emaExpTime >= MIN_EMA_PERIOD && _emaExpTime <= MAX_EMA_PERIOD, "Invalid EMA Timestamp");
        require(!isInitialized, "Already initialized");
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        EMA_EXPTime = _emaExpTime;
        maxPriceDeviation = _maxPriceDeviation;
        validationThreshold = _validationThreshold;
        randomSamplingWindow = _randomSamplingWindow;
        callBackGasLimit = _callBackGasLimit;
        REQUEST_CONFIRMATIONS = _requestConfirmations;

        if (_sequencerUptimeFeed != address(0)) {
            sequencerUptimeFeed = AggregatorV2V3Interface(_sequencerUptimeFeed);
            isL2 = true;
        } else {
            sequencerUptimeFeed = AggregatorV2V3Interface(address(0));
            isL2 = false;
        }

        isInitialized = true;
    }

    function addAsset(address _assetAddress, address _priceFeed) external onlyOwner {
        require(_assetAddress != address(0), "Invalid asset address");
        require(_priceFeed != address(0), "Invalid price feed address");
        require(assets[_assetAddress].assetAddress == address(0), "Asset already exists");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeed);
        uint8 decimals = priceFeed.decimals();

        // Get initial price with sequencer check
        uint256 normalizedPrice = _getValidatedPrice(_priceFeed, decimals);

        assets[_assetAddress] = Asset({
            assetAddress: _assetAddress,
            price: normalizedPrice,
            lastVerifiedPrice: normalizedPrice,
            lastUpdateTime: block.timestamp,
            emaPrice: normalizedPrice,
            isDeprecated: false,
            lastRequestId: 0,
            priceFeed: AggregatorV3Interface(_priceFeed),
            decimals: decimals
        });

        assetList.push(_assetAddress);
    }

    function updateAssetPrice(address assetAddr) external {
        require(!assets[assetAddr].isDeprecated, "Asset is deprecated");

        // //If asset has a pending validation,wait for it
        if (assets[assetAddr].lastRequestId != 0) {
            return;
        }

        // // Get current price
        uint256 currentPrice = _getValidatedPrice(address(assets[assetAddr].priceFeed), assets[assetAddr].decimals);

        // If price isn't within the deviation range validation will be triggered
        if (!isPriceWithinDeviation(currentPrice, assets[assetAddr].price)) {
            // Trigger validation for this asset
            address[] memory singleAsset = new address[](1);
            singleAsset[0] = assetAddr;
            _requestRandomValidation(singleAsset);
        } else {
            _updateAssetPrice(assetAddr, currentPrice);
        }
    }

    function calculateEMAPrice(address assetAddr) public view returns (uint256) {
        Asset storage asset = assets[assetAddr];
        if (asset.assetAddress == address(0)) {
            revert AssetNotFound(assetAddr);
        }

        uint256 timeDelta = block.timestamp - asset.lastUpdateTime;
        if (timeDelta == 0) {
            return asset.emaPrice;
        }

        uint256 decayFactor = calculateDecayFactor(timeDelta);
        uint256 weight = PRECISION - decayFactor;

        return (asset.emaPrice * decayFactor + asset.price * weight) / PRECISION;
    }

    function calculateDecayFactor(uint256 timeDelta) public view returns (uint256) {
        return _calculateDecayFactor(timeDelta);
    }

    function _calculateDecayFactor(uint256 timeDelta) internal view returns (uint256) {
        SD59x18 decayTime = sd(int256((timeDelta * 1e18) / EMA_EXPTime) * -1);
        return uint256(exp(decayTime).unwrap());
    }

    // Meant to be called by validators/users to trigger priceValidation on a constant basis, can be automated..
    function requestPriceValidation() external {
        require(block.timestamp >= lastValidationTime + validationInterval, "Too soon for validation");
        require(assetList.length > 0, "No assets to validate");

        address[] memory assetsToValidate = new address[](assetList.length);
        uint256 validAssetCount = 0;

        for (uint256 index = 0; index < assetList.length; index++) {
            if (!assets[assetList[index]].isDeprecated) {
                assetsToValidate[validAssetCount] = assetList[index];
                validAssetCount++;
            }
        }

        address[] memory finalAssets = new address[](validAssetCount);
        for (uint256 index = 0; index < validAssetCount; index++) {
            finalAssets[index] = assetsToValidate[index];
        }

        if (finalAssets.length > 0) {
            _requestRandomValidation(finalAssets);
            lastValidationTime = block.timestamp;
        }
    }

    // //Called by the vrf (callback) when random price validation is requested..
    // function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external virtual {
    //     _fulfillRandomWords(requestId, randomWords);
    // }

    function _requestRandomValidation(address[] memory assetsToValidate) internal {
        // Storing the current prices
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: callBackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );

        requestIdToTimestamp[requestId] = block.timestamp;
        requestIdToAssets[requestId] = assetsToValidate;

        // Storing the current prices for validation
        for (uint256 index = 0; index < assetsToValidate.length; index++) {
            address assetAddr = assetsToValidate[index];
            uint256 validatedPrice =
                _getValidatedPrice(address(assets[assetAddr].priceFeed), assets[assetAddr].decimals);
            requestIdToAssetPrice[requestId][assetAddr] = validatedPrice;
            // Update lastRequestId for tracking
            assets[assetAddr].lastRequestId = requestId;
        }

        emit RandomValidationRequested(requestId, assetsToValidate);
    }

    function _getValidatedPrice(address priceFeedAddr, uint8 decimals) internal returns (uint256) {
        // We Check the status of the sequencer if the sequencer is up or down in case of an Layer-2 Chain.
        if (isL2) {
            _checkSequencerStatus();
        }

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddr);
        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price from feed");
        require(block.timestamp - updatedAt <= 3600, "Price feed stale");

        return _normalizePrice(uint256(price), decimals);
    }

    function _checkSequencerStatus() internal {
        //If not L2 , no need to check on sequencer uptime
        if (!isL2 || address(sequencerUptimeFeed) == address(0)) {
            return;
        }

        (, int256 answer, uint256 startedAt, uint256 updatedAt,) = sequencerUptimeFeed.latestRoundData();

        // Check if sequencer feed is stale
        require(block.timestamp - updatedAt <= SEQUENCER_FEED_HEARTBEAT, "Sequencer feed stale");

        // Answer == 0, Sequencer is up
        //Answer == 1, Sequencer is down
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert SequencerDown();
        }

        // Grace period check
        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert GracePeriodNotOver();
        }

        emit SequencerStatusChecked(isSequencerUp, timeSinceUp);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual  {
        if (randomWords.length == 0) {
            revert InvalidRandomness();
        }

        uint256 requestTime = requestIdToTimestamp[requestId];
        require(requestTime > 0, "Invalid request ID");

        // Check if the random validation should proceed based on sampling window
        uint256 randomValue = randomWords[0];
        bool shouldValidate = _shouldValidateBasedOnRandomness(randomValue, requestTime);

        address[] memory assetsToValidate = requestIdToAssets[requestId];

        if (shouldValidate) {
            for (uint256 index = 0; index < assetsToValidate.length; index++) {
                address assetAddr = assetsToValidate[index];
                uint256 storedPrice = requestIdToAssetPrice[requestId][assetAddr];

                uint256 currentNormalizedPrice =
                    _getValidatedPrice(address(assets[assetAddr].priceFeed), assets[assetAddr].decimals);

                //Use the stored price if it's close to the current price , otherwise use the current one
                uint256 finalPrice =
                    _isPriceStillValid(storedPrice, currentNormalizedPrice) ? storedPrice : currentNormalizedPrice;

                //Updating the asset price after validation
                _updateAssetPrice(assetAddr, finalPrice);
                assets[assetAddr].lastVerifiedPrice = finalPrice;
            }

            emit ValidationCompleted(requestId, assetsToValidate);
        } else {
            //If validation skipped we still have to keep old prices
            for (uint256 index = 0; index < assetsToValidate.length; index++) {
                address assetAddr = assetsToValidate[index];
                // Resetting the lastRequestId since this request is complete
                assets[assetAddr].lastRequestId = 0;
            }
        }

        delete requestIdToTimestamp[requestId];
        delete requestIdToAssets[requestId];
        for (uint256 index = 0; index < assetsToValidate.length; index++) {
            delete requestIdToAssetPrice[requestId][assetsToValidate[index]];
        }
    }

    function isPriceWithinDeviation(uint256 newPrice, uint256 basePrice) public view returns (bool) {
        uint256 deviation = calculatePriceDeviation(newPrice, basePrice);
        return deviation <= maxPriceDeviation;
    }

    //INTERNAL FUNCTIONS
    function _updateAssetPrice(address assetAddr, uint256 newPrice) internal {
        Asset storage asset = assets[assetAddr];

        // Calculate new EMA Price
        uint256 timeDelta = block.timestamp - asset.lastUpdateTime;
        uint256 newEmaPrice = timeDelta == 0 ? asset.emaPrice : calculateEMAPrice(assetAddr);

        // Update with new price impact
        if (timeDelta > 0) {
            uint256 decayFactor = _calculateDecayFactor(timeDelta);
            uint256 weight = PRECISION - decayFactor;
            newEmaPrice = (asset.emaPrice * decayFactor + newPrice * weight) / PRECISION;
        }

        asset.price = newPrice;
        asset.emaPrice = newEmaPrice;
        asset.lastUpdateTime = block.timestamp;

        emit AssetPriceUpdated(assetAddr, newPrice, newEmaPrice);
    }

    //To normalize the decimal precision
    function _normalizePrice(uint256 price, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) {
            return price;
        } else if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else {
            return price / (10 ** (decimals - 18));
        }
    }

    //  Determines whether to perform the validation or not
    function _shouldValidateBasedOnRandomness(uint256 randomValue, uint256 requestTime) internal view returns (bool) {
        return (randomValue % 100) < validationThreshold;
    }

    function _isPriceStillValid(uint256 storedPrice, uint256 currentPrice) internal pure returns (bool) {
        uint256 deviation = storedPrice > currentPrice
            ? ((storedPrice - currentPrice) * 100) / storedPrice
            : ((currentPrice - storedPrice) * 100 / storedPrice);
        return deviation <= 5; //5% Tolerance for price deviations
    }

    function calculatePriceDeviation(uint256 newPrice, uint256 basePrice) public pure returns (uint256) {
        if (basePrice == 0) return 0;
        return ((newPrice > basePrice ? newPrice - basePrice : basePrice - newPrice) * 100) / basePrice;
    }

    function getAssetPrice(address assetAddr)
        external
        view
        returns (uint256 price, uint256 emaPrice, uint256 lastUpdate)
    {
        Asset storage asset = assets[assetAddr];
        if (asset.assetAddress == address(0)) {
            revert AssetNotFound(assetAddr);
        }
        return (asset.price, calculateEMAPrice(assetAddr), asset.lastUpdateTime);
    }

    function getAssetCount() external view returns (uint256) {
        return assetList.length;
    }

    function getAssetAtIndex(uint256 index) external view returns (address) {
        require(index < assetList.length, "Index out of bounds");
        return assetList[index];
    }

    function getSequencerUptimeFeed() external view returns (address) {
        return address(sequencerUptimeFeed);
    }

    function isAssetDeprecated(address assetAddress) external view returns (bool) {
        return assets[assetAddress].isDeprecated;
    }

    function isL2Network() external view returns (bool) {
        return isL2;
    }

    function setGracePeriod(uint256 _gracePeriod) external onlyOwner {
        GRACE_PERIOD_TIME = _gracePeriod;
    }

    function setSequencerHeartbeat(uint256 _hearbeat) external onlyOwner {
        SEQUENCER_FEED_HEARTBEAT = _hearbeat;
    }

    function setValidationInterval(uint256 _interval) external onlyOwner {
        validationInterval = _interval;
    }
}
