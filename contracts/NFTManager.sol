// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155Holder.sol";
import "./utility/LibMath.sol";
import "./utility/Whitelist.sol";
import "./utility/SyntheticNFT.sol";
import "./interfaces/IPriceResolver.sol";
import "./interfaces/ISyntheticNFT.sol";
import "./interfaces/INFTManager.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakeFactory.sol";

/**
 * @title A contract to collaterizes LP and mints NFT
 */

contract NFTManager is ReentrancyGuard, Whitelist, INFTManager, ERC1155Holder {
    using LibMathSigned for int256;
    using LibMathUnsigned for uint256;

    using SafeERC20 for IERC20;

    enum ContractState {
        INITIAL,
        NORMAL,
        EMERGENCY,
        EXPIRED
    }

    struct SyntheticVariant {
        // name of the variant
        string name;
        // token id for this variant
        uint256 tokenId;
        // value
        uint256 tokenValue;
        // raw collateral on this variant
        uint256 totalRawCollateral;
        // total tokens that been minted
        uint256 totalOutstanding;
        // total tokens that been issued
        uint256 totalIssued;
        // total tokens that been burnt
        uint256 totalBurnt;
        // active status
        bool disabled;
    }

    struct Minter {
        mapping(uint8 => uint256) amount;
        uint256 timestamp;
        uint256 redeemClaimed;
    }

    // Name of the contract
    string public name;
    // Contract state
    ContractState public state;
    // Price resolver contract.
    IPriceResolver public priceResolver;
    // Synthetic NFT created by this contract.
    ISyntheticNFT public override syntheticNFT;
    // Collateral share
    IPancakePair public override collateralShare;
    // Collateral share's symbol for price calculation
    bytes32 public collateralShareSymbol;
    // Target currency in the registry
    bytes32 public syntheticSymbol;
    // Synthetic NFT variants
    mapping(uint8 => SyntheticVariant) public syntheticVariants;
    // Total Synthetic NFT variants
    uint8 public syntheticVariantCount;
    // Track minter activities
    mapping(address => Minter) private minters;
    // Total raw collateral
    uint256 public totalRawCollateral;
    // Total NFT synthetics outstanding
    uint256 public totalOutstanding;
    // Dev address
    address public devAddress;
    // Redeem fee
    uint256 public redeemFee;
    // Ignore offset/discount fees when active
    bool public offsetDisabled;
    bool public discountDisabled;

    // cooldown period before the minter can mint again
    uint256 COOLDOWN_PERIOD = 1 minutes;
    // max NFT that can be minted per time
    uint256 MAX_NFT = 20;

    uint256 constant ONE = 1 ether; // 1
    uint256 constant MAX_UINT256 = uint256(-1);
    address constant ROUTER_ADDRESS =
        0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; // Quickswap Router
    int256 constant BASE = 10 ether;
    int256 constant K = 9.3 ether;

    event PositionCreated(
        address minter,
        uint8 variantId,
        uint256 tokenValue,
        uint256 collateralAmount,
        uint256 tokenAmount
    );

    event PositionRemoved(
        address minter,
        uint8 variantId,
        uint256 tokenValue,
        uint256 collateralAmount,
        uint256 tokenAmount
    );

    constructor(
        string memory _name,
        string memory _nftUri,
        address _priceResolverAddress,
        address _collateralShareAddress, // LP TOKEN
        bytes32 _collateralShareSymbol, // LP TOKEN
        bytes32 _syntheticSymbol,
        address _devAddress
    ) public nonReentrant {
        name = _name;
        syntheticSymbol = _syntheticSymbol;
        state = ContractState.INITIAL;
        collateralShare = IPancakePair(_collateralShareAddress);
        collateralShareSymbol = _collateralShareSymbol;

        priceResolver = IPriceResolver(_priceResolverAddress);

        redeemFee = 30000000000000000; // 3.0%

        // Deploy the synthetic NFT contract
        SyntheticNFT deployedContract = new SyntheticNFT(_nftUri);
        syntheticNFT = ISyntheticNFT(address(deployedContract));

        devAddress = _devAddress;

        // add dev into the whitelist
        addAddress(_devAddress);

        if (_devAddress != msg.sender) {
            addAddress(msg.sender);
        }

        if (collateralShare.token0() != address(0)) {
            IERC20(collateralShare.token0()).approve(
                ROUTER_ADDRESS,
                MAX_UINT256
            );
            IERC20(collateralShare.token1()).approve(
                ROUTER_ADDRESS,
                MAX_UINT256
            );
            IERC20(address(collateralShare)).approve(
                ROUTER_ADDRESS,
                MAX_UINT256
            );
        }
    }

    function estimateMint(uint8 _id, uint256 _tokenAmount)
        public
        view
        validateId(_id, _tokenAmount)
        returns (uint256 baseTokenAmount, uint256 pairTokenAmount, uint256 lpAmount, uint256 discount)
    {
        ( baseTokenAmount, pairTokenAmount, lpAmount, discount) = _estimateMint(
            _id,
            _tokenAmount
        );
    }

    function estimateRedeem(uint8 _id, uint256 _tokenAmount)
        public
        view
        validateId(_id, _tokenAmount)
        returns (
            uint256 baseTokenAmount,
            uint256 pairTokenAmount,
            uint256 lpAmount,
            uint256 offset
        )
    {
        (baseTokenAmount, pairTokenAmount, lpAmount, offset ) = _estimateRedeem(
            _id,
            _tokenAmount
        );
    }

    function mint(uint8 _id, uint256 _tokenAmount)
        public
        nonReentrant
        isReady
        validateId(_id, _tokenAmount)
    {
        (uint256 baseAmount, uint256 pairAmount, , ) = _estimateMint(
            _id,
            _tokenAmount
        );

        // takes ERC-20 tokens
        IERC20(collateralShare.token0()).safeTransferFrom(
            msg.sender,
            address(this),
            baseAmount
        );
        IERC20(collateralShare.token1()).safeTransferFrom(
            msg.sender,
            address(this),
            pairAmount
        );

        (, , uint256 lpAmount) = IPancakeRouter02(ROUTER_ADDRESS).addLiquidity(
            collateralShare.token0(),
            collateralShare.token1(),
            baseAmount,
            pairAmount,
            baseAmount.wmul(0.97 ether),
            pairAmount.wmul(0.97 ether),
            address(this),
            now + 86400
        );

        _createPosition(_id, lpAmount, _tokenAmount);

        // mint NFT back to the minter
        syntheticNFT.mint(
            msg.sender,
            syntheticVariants[_id].tokenId,
            _tokenAmount,
            _toBytes(0)
        );
    }

    

    function redeem(uint8 _id, uint256 _tokenAmount)
        public
        nonReentrant
        isReady
        validateId(_id, _tokenAmount)
    {
        (, , uint256 lpAmount,) = _estimateRedeem(_id, _tokenAmount);

        _removePosition(_id, lpAmount, _tokenAmount);

        // burn NFT
        syntheticNFT.safeTransferFrom(
            msg.sender,
            address(this),
            syntheticVariants[_id].tokenId,
            _tokenAmount,
            _toBytes(0)
        );
        syntheticNFT.burn(
            address(this),
            syntheticVariants[_id].tokenId,
            _tokenAmount
        );

        (uint256 baseTokenAmount, uint256 pairTokenAmount) = IPancakeRouter02(
            ROUTER_ADDRESS
        ).removeLiquidity(
                collateralShare.token0(),
                collateralShare.token1(),
                lpAmount,
                0,
                0,
                address(this),
                now + 86400
            );

        // return tokens back
        IERC20(collateralShare.token0()).transfer(msg.sender, baseTokenAmount);
        IERC20(collateralShare.token1()).transfer(msg.sender, pairTokenAmount);
    }

    

    // get price per 1 synthetic token
    function getSyntheticPrice() public view returns (uint256) {
        require(
            priceResolver.isValid(syntheticSymbol),
            "syntheticSymbol is not valid"
        );
        return priceResolver.getCurrentPrice(syntheticSymbol);
    }

    // get price per 1 LP
    function getCollateralSharePrice() public view returns (uint256) {
        require(
            priceResolver.isValid(collateralShareSymbol),
            "collateralShareSymbol is not valid"
        );
        return priceResolver.getCurrentPrice(collateralShareSymbol);
    }

    // total token that the given minter has been minted
    function getMinterAmount(address _minter, uint8 _id)
        public
        view
        returns (uint256)
    {
        return minters[_minter].amount[_id];
    }

    // check global CR for this synthetic NFT
    function globalCollatelizationRatio() public view returns (uint256) {
        require(totalRawCollateral > 0, "No collaterals in the contract");
        return
            _calculateCollateralizationRatio(
                totalRawCollateral,
                totalOutstanding
            );
    }

    // check CR for each variant
    function variantCollatelizationRatio(uint8 _id)
        public
        view
        returns (uint256)
    {
        require(syntheticVariantCount > _id, "Invalid given _id");

        if (syntheticVariants[_id].totalRawCollateral > 0) {
            return
                _calculateCollateralizationRatio(
                    syntheticVariants[_id].totalRawCollateral,
                    syntheticVariants[_id].totalOutstanding
                );
        } else {
            // return 100% when no collaterals
            return 1 ether;
        }
    }

    function targetCollatelizationRatio(uint8 _id)
        public
        view
        returns (int256, int256)
    {
        require(syntheticVariantCount > _id, "Invalid given _id");
        return (_calculateTargetCROffset(_id), _calculateTargetCRDiscount(_id));
    }

    // ONLY ADMIN CAN PROCEED

    // add NFT variant
    function addSyntheticVariant(
        string memory _name,
        uint256 _tokenId,
        uint256 _tokenValue
    ) public nonReentrant onlyWhitelisted {
        syntheticVariants[syntheticVariantCount].name = _name;
        syntheticVariants[syntheticVariantCount].tokenId = _tokenId;
        syntheticVariants[syntheticVariantCount].tokenValue = _tokenValue;

        syntheticVariantCount += 1;
    }

    // enable/disable synthetic NFT variant
    function setSyntheticVariantDisable(uint8 _id, bool _disabled)
        public
        nonReentrant
        onlyWhitelisted
    {
        require(syntheticVariantCount > _id, "Invalid given _id");
        syntheticVariants[_id].disabled = _disabled;
    }

    // emergency withdraw ERC-20 tokens out of the contract
    function withdrawErc20(address _tokenAddress, uint256 _amount)
        public
        nonReentrant
        onlyWhitelisted
    {
        IERC20(_tokenAddress).transfer(msg.sender, _amount);
    }

    // force mint ERC-1155
    function forceMint(
        uint8 _id,
        uint256 _collateralAmount,
        uint256 _tokenAmount
    ) public nonReentrant onlyWhitelisted validateId(_id, _tokenAmount) {
        _createPosition(_id, _collateralAmount, _tokenAmount);

        // FIXME: use safeTransferFrom
        // take collaterals
        collateralShare.transferFrom(
            msg.sender,
            address(this),
            _collateralAmount
        );

        // mint NFT back to the minter
        syntheticNFT.mint(
            msg.sender,
            syntheticVariants[_id].tokenId,
            _tokenAmount,
            _toBytes(0)
        );
    }

    function forceRedeem(
        uint8 _id,
        uint256 _collateralAmount,
        uint256 _tokenAmount
    ) public nonReentrant onlyWhitelisted validateId(_id, _tokenAmount) {
        _removePosition(_id, _collateralAmount, _tokenAmount);

        // burn NFT
        syntheticNFT.safeTransferFrom(
            msg.sender,
            address(this),
            syntheticVariants[_id].tokenId,
            _tokenAmount,
            _toBytes(0)
        );
        syntheticNFT.burn(
            address(this),
            syntheticVariants[_id].tokenId,
            _tokenAmount
        );

        // return collaterals back to the minter
        collateralShare.transfer(msg.sender, _collateralAmount);
    }

    // update the contract state
    function setContractState(ContractState _state)
        public
        nonReentrant
        onlyWhitelisted
    {
        state = _state;
    }

    // update the price resolver contract
    function setPriceResolver(address _priceResolverAddress)
        public
        nonReentrant
        onlyWhitelisted
    {
        priceResolver = IPriceResolver(_priceResolverAddress);
    }

    // update dev address
    function setDevAddress(address _devAddress)
        public
        nonReentrant
        onlyWhitelisted
    {
        devAddress = _devAddress;
    }

    // update NFT uri
    function setNftUri(string memory _uri) public nonReentrant onlyWhitelisted {
        syntheticNFT.setUri(_uri);
    }

    // update redeem fees
    function setRedeemFee(uint256 _fee) public nonReentrant onlyWhitelisted {
        redeemFee = _fee;
    }

    // enable / disable offset fees
    function setOffsetDisabled(bool _active) public nonReentrant onlyWhitelisted {
        offsetDisabled = _active;
    }

    // enable / disable discount fees
    function setDiscountDisabled(bool _active) public nonReentrant onlyWhitelisted {
        discountDisabled = _active;
    }

    // INTERNAL FUNCTIONS

    // Check if the state is ready
    modifier isReady() {
        require((state) == ContractState.NORMAL, "Contract state is not ready");
        _;
    }

    modifier validateId(uint8 _id, uint256 _tokenAmount) {
        require(syntheticVariantCount > _id, "Invalid given _id");
        require(
            syntheticVariants[_id].disabled == false,
            "The given _id is disabled"
        );
        require(_tokenAmount != 0, "_tokenAmount can't be zero");
        require(MAX_NFT >= _tokenAmount, "Exceed MAX_NFT");
        _;
    }

    function _toBytes(uint256 x) internal pure returns (bytes memory b) {
        b = new bytes(32);
        assembly {
            mstore(add(b, 32), x)
        }
    }

    function _createPosition(
        uint8 _id,
        uint256 _collateralAmount,
        uint256 _tokenAmount
    ) internal {
        syntheticVariants[_id].totalOutstanding += (
            syntheticVariants[_id].tokenValue.mul(_tokenAmount)
        );
        syntheticVariants[_id].totalIssued += _tokenAmount;
        syntheticVariants[_id].totalRawCollateral += _collateralAmount;

        minters[msg.sender].amount[_id] += _tokenAmount;
        minters[msg.sender].timestamp = now;

        emit PositionCreated(
            msg.sender,
            _id,
            syntheticVariants[_id].tokenValue,
            _collateralAmount,
            _tokenAmount
        );

        totalRawCollateral = totalRawCollateral.add(_collateralAmount);
        totalOutstanding = totalOutstanding.add(
            syntheticVariants[_id].tokenValue.mul(_tokenAmount)
        );
    }

    function _removePosition(
        uint8 _id,
        uint256 _collateralAmount,
        uint256 _tokenAmount
    ) internal {
        syntheticVariants[_id].totalOutstanding = syntheticVariants[_id]
            .totalOutstanding
            .sub(syntheticVariants[_id].tokenValue.mul(_tokenAmount));
        syntheticVariants[_id].totalBurnt += _tokenAmount;
        syntheticVariants[_id].totalRawCollateral = syntheticVariants[_id]
            .totalRawCollateral
            .sub(_collateralAmount);

        minters[msg.sender].amount[_id] = minters[msg.sender].amount[_id].sub(
            _tokenAmount
        );
        minters[msg.sender].timestamp = now;

        emit PositionRemoved(
            msg.sender,
            _id,
            syntheticVariants[_id].tokenValue,
            _collateralAmount,
            _tokenAmount
        );

        totalRawCollateral = totalRawCollateral.sub(_collateralAmount);
        totalOutstanding = totalOutstanding.sub(
            syntheticVariants[_id].tokenValue.mul(_tokenAmount)
        );
    }

    function _calculateCollateralizationRatio(
        uint256 collateralAmount,
        uint256 syntheticAmount
    ) internal view returns (uint256) {
        uint256 collateralRate = priceResolver.getCurrentPrice(
            collateralShareSymbol
        );
        uint256 syntheticRate = priceResolver.getCurrentPrice(syntheticSymbol);

        uint256 numerator = collateralRate.wmul(collateralAmount);
        uint256 denominator = syntheticRate.wmul(syntheticAmount);

        return numerator.wdiv(denominator);
    }

    function _estimateInputs(uint8 _id, uint256 _tokenAmount)
        internal
        view
        returns (
            uint256 baseTokenAmount,
            uint256 pairTokenAmount,
            uint256 lpAmount
        )
    {
        uint256 syntheticPrice = priceResolver.getCurrentPrice(syntheticSymbol);
        uint256 sharePrice = priceResolver.getCurrentPrice(
            collateralShareSymbol
        );
        uint256 mintedValue = syntheticPrice.wmul(
            syntheticVariants[_id].tokenValue.mul(_tokenAmount)
        );
        uint256 lpNeeded = mintedValue.wdiv(sharePrice);

        lpAmount = lpNeeded;

        uint256 baseInLp = IERC20(collateralShare.token0()).balanceOf(
            address(collateralShare)
        );
        uint256 pairInLp = IERC20(collateralShare.token1()).balanceOf(
            address(collateralShare)
        );

        baseTokenAmount = (lpNeeded.mul(baseInLp)).div(
            collateralShare.totalSupply()
        );
        pairTokenAmount = (lpNeeded.mul(pairInLp)).div(
            collateralShare.totalSupply()
        );
    }

    function _estimateRedeem(uint8 _id, uint256 _tokenAmount)
        internal
        view
        returns (
            uint256 baseTokenAmount,
            uint256 pairTokenAmount,
            uint256 lpAmount,
            uint256 offset
        )
    {
        (baseTokenAmount, pairTokenAmount, lpAmount) = _estimateInputs(
            _id,
            _tokenAmount
        );

        int256 targetCR = _calculateTargetCROffset(_id);

        // adjusting redeemed amount when CR < 1
        if (targetCR != 1 ether && targetCR > 0 && offsetDisabled == false) {
            uint256 newTotalCollateral = syntheticVariants[_id].totalRawCollateral.sub(lpAmount);
            uint256 newCR = _calculateCollateralizationRatio(
                newTotalCollateral,
                syntheticVariants[_id].totalOutstanding.sub(
                    syntheticVariants[_id].tokenValue.mul(_tokenAmount)
                )
            );

            uint256 adjustedTotalCollateral = ((targetCR.toUint256()).wmul(newTotalCollateral)).wdiv(newCR);
            if (adjustedTotalCollateral > newTotalCollateral) {
                offset = (adjustedTotalCollateral.sub( newTotalCollateral )).wmul( lpAmount.wdiv(syntheticVariants[_id].totalRawCollateral) );
            }
            
            uint256 lpAmountWithOffset = lpAmount.sub(offset);

            baseTokenAmount = baseTokenAmount.wmul( lpAmountWithOffset.wdiv(lpAmount) );
            pairTokenAmount = pairTokenAmount.wmul( lpAmountWithOffset.wdiv(lpAmount) );
            lpAmount = lpAmountWithOffset;
        }
    }

    function _estimateMint(uint8 _id, uint256 _tokenAmount)
        internal
        view
        returns (
            uint256 baseTokenAmount,
            uint256 pairTokenAmount,
            uint256 lpAmount,
            uint256 discount
        )
    {
        (baseTokenAmount, pairTokenAmount, lpAmount) = _estimateInputs(
            _id,
            _tokenAmount
        );

        int256 targetCR = _calculateTargetCRDiscount(_id);

        // adjusting minted amount when target CR > current CR > 1
        if (targetCR > 1 ether && discountDisabled == false) {

            uint256 newTotalCollateral = syntheticVariants[_id].totalRawCollateral.add(lpAmount);
            uint256 newCR = _calculateCollateralizationRatio(
                newTotalCollateral,
                syntheticVariants[_id].totalOutstanding.add(
                    syntheticVariants[_id].tokenValue.mul(_tokenAmount)
                )
            );

            uint256 adjustedTotalCollateral = ((targetCR.toUint256()).wmul(newTotalCollateral)).wdiv(newCR);
            
            if (newTotalCollateral > adjustedTotalCollateral) {
                discount = newTotalCollateral.sub(adjustedTotalCollateral).wmul( lpAmount.wdiv(syntheticVariants[_id].totalRawCollateral) );
            }
            // discount = syntheticVariants[_id].totalRawCollateral.sub(adjustedTotalCollateral).wmul( lpAmount.wdiv(syntheticVariants[_id].totalRawCollateral) );
            uint256 lpAmountWithDiscount = lpAmount.sub(discount);

            baseTokenAmount = baseTokenAmount.wmul( lpAmountWithDiscount.wdiv(lpAmount) );
            pairTokenAmount = pairTokenAmount.wmul( lpAmountWithDiscount.wdiv(lpAmount) );
            lpAmount = lpAmountWithDiscount;
        }

    }

    // when cr is between 0 -> 1
    function _calculateTargetCROffset(uint8 _id)
        internal
        view
        returns (int256)
    {
        int256 cr = variantCollatelizationRatio(_id).toInt256();
        int256 result = _calculateTargetCR(cr);
        if (cr > 0 && 1 ether >= result) {
            return result;
        } else {
            return 1 ether;
        }
    }

    // when cr is between 1 -> infinity
    function _calculateTargetCRDiscount(uint8 _id)
        internal
        view
        returns (int256)
    {
        int256 cr = variantCollatelizationRatio(_id).toInt256();
        int256 result = _calculateTargetCR(cr);
        if (cr > 1 ether && cr > result) {
            return _calculateTargetCR(cr);
        } else {
            return 1 ether;
        }
    }

    // log^b(kx+1)
    function _calculateTargetCR(int256 _cr) internal pure returns (int256) {
        return BASE.logBase((K.wmul(_cr)).add(1 ether));
    }
}