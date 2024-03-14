// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "src/Kernel.sol";
import "forge-std/Test.sol";
import "src/mock/MockValidator.sol";
import "src/mock/MockPolicy.sol";
import "src/mock/MockSigner.sol";
import "src/core/PermissionManager.sol";
import "./erc4337Util.sol";

contract SimpleProxy {
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address _target) {
        assembly {
            sstore(IMPLEMENTATION_SLOT, _target)
        }
    }

    function _getImplementation() internal view returns (address target) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            target := sload(slot)
        }
    }

    receive() external payable {
        (bool success,) = _getImplementation().delegatecall("");
        require(success, "delegatecall failed");
    }

    fallback(bytes calldata) external payable returns (bytes memory) {
        (bool success, bytes memory ret) = _getImplementation().delegatecall(msg.data);
        require(success, "delegatecall failed");
        return ret;
    }
}

contract MockCallee {
    uint256 public value;

    function setValue(uint256 _value) public {
        value = _value;
    }
}

abstract contract KernelTestBase is Test {
    Kernel kernel;
    IEntryPoint entrypoint;
    ValidationId rootValidation;

    struct RootValidationConfig {
        IHook hook;
        bytes validatorData;
        bytes hookData;
    }

    RootValidationConfig rootValidationConfig;
    MockValidator mockValidator;
    MockCallee callee;

    IValidator enabledValidator;
    EnableValidatorConfig validatorConfig;

    struct EnableValidatorConfig {
        IHook hook;
        bytes hookData;
        bytes validatorData;
    }

    PermissionId enabledPermission;
    EnablePermissionConfig permissionConfig;

    struct EnablePermissionConfig {
        IHook hook;
        bytes hookData;
        IPolicy[] policies;
        bytes[] policyData;
        ISigner signer;
        bytes signerData;
    }
    // todo selectorData

    modifier whenInitialized() {
        kernel.initialize(
            rootValidation, rootValidationConfig.hook, rootValidationConfig.validatorData, rootValidationConfig.hookData
        );
        assertEq(kernel.currentNonce(), 2);
        _;
    }

    function setUp() public {
        entrypoint = IEntryPoint(EntryPointLib.deploy());
        mockValidator = new MockValidator();
        rootValidation = ValidatorLib.validatorToIdentifier(mockValidator);
        Kernel impl = new Kernel(entrypoint);
        callee = new MockCallee();
        kernel = Kernel(payable(address(new SimpleProxy(address(impl)))));
        _setRootValidationConfig();
        _setEnableValidatorConfig();
        _setEnablePermissionConfig();
    }

    // things to override on test
    function _setRootValidationConfig() internal {}

    function _setEnableValidatorConfig() internal {
        enabledValidator = new MockValidator();
    }

    function _setEnablePermissionConfig() internal {
        IPolicy[] memory policies = new IPolicy[](2);
        MockPolicy mockPolicy = new MockPolicy();
        MockPolicy mockPolicy2 = new MockPolicy();
        policies[0] = mockPolicy;
        policies[1] = mockPolicy2;
        bytes[] memory policyData = new bytes[](2);
        policyData[0] = "policy1";
        policyData[1] = "policy2";
        MockSigner mockSigner = new MockSigner();

        permissionConfig.policies = policies;
        permissionConfig.signer = mockSigner;
        permissionConfig.policyData = policyData;
        permissionConfig.signerData = "signer";
    }

    // kernel initialize scenario
    function testInitialize() external {
        ValidationId vId = ValidatorLib.validatorToIdentifier(mockValidator);

        kernel.initialize(vId, IHook(address(0)), hex"", hex"");
        assertTrue(kernel.rootValidator() == vId);
        ValidationManager.ValidationConfig memory config;
        config = kernel.validatorConfig(vId);
        assertEq(config.nonce, 1);
        assertEq(address(config.hook), address(1));
        assertEq(mockValidator.isInitialized(address(kernel)), true);
        assertEq(kernel.currentNonce(), 2);
    }

    // root validator cases
    function _rootValidatorFailurePreCondition() internal virtual {
        mockValidator.sudoSetSuccess(false);
    }

    function _rootValidatorSuccessPreCondition() internal virtual {
        mockValidator.sudoSetSuccess(true);
    }

    function _rootValidatorSuccessSignature() internal view virtual returns (bytes memory) {
        return abi.encodePacked("success");
    }

    function _rootValidatorFailureSignature() internal view virtual returns (bytes memory) {
        return abi.encodePacked("failure");
    }

    function _rootValidatorSuccessCheck() internal virtual {
        assertEq(123, callee.value());
    }

    function _rootValidatorFailureCheck() internal virtual {
        assertEq(0, callee.value());
    }

    function _prepareRootUserOp(bool success) internal returns (PackedUserOperation memory op) {
        if (success) {
            _rootValidatorSuccessPreCondition();
        } else {
            _rootValidatorFailurePreCondition();
        }
        op = PackedUserOperation({
            sender: address(kernel),
            nonce: entrypoint.getNonce(address(kernel), 0),
            initCode: hex"",
            callData: abi.encodeWithSelector(
                kernel.execute.selector,
                ExecLib.encodeSimpleSingle(),
                ExecLib.encodeSingle(address(callee), 0, abi.encodeWithSelector(callee.setValue.selector, 123))
                ),
            accountGasLimits: bytes32(abi.encodePacked(uint128(1000000), uint128(1000000))),
            preVerificationGas: 1000000,
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
            paymasterAndData: hex"",
            signature: success ? _rootValidatorSuccessSignature() : _rootValidatorFailureSignature()
        });
    }

    function testRootValidateUserOpSuccess() external whenInitialized {
        vm.deal(address(kernel), 1e18);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _prepareRootUserOp(true);
        entrypoint.handleOps(ops, payable(address(0xdeadbeef)));
        _rootValidatorSuccessCheck();
    }

    function testRootValidateUserOpFail() external whenInitialized {
        vm.deal(address(kernel), 1e18);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _prepareRootUserOp(false);
        vm.expectRevert();
        entrypoint.handleOps(ops, payable(address(0xdeadbeef)));
    }

    function encodeEnableSignature(
        IHook hook,
        bytes memory validatorData,
        bytes memory hookData,
        bytes memory selectorData,
        bytes memory enableSig,
        bytes memory userOpSig
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            abi.encodePacked(hook), abi.encode(validatorData, hookData, selectorData, enableSig, userOpSig)
        );
    }

    function encodePermissionValidatorData() internal returns (bytes memory data) {}

    function encodeHookData() internal returns (bytes memory data) {}

    function encodeSelectorData() internal returns (bytes memory data) {}

    function getEnableSig(bool success) internal returns (bytes memory data) {
        if (success) {
            return "enableSig";
        } else {
            return "failEnableSig";
        }
    }

    function getValidatorSig(bool success) internal returns (bytes memory data) {
        if (success) {
            return "userOpSig";
        } else {
            return "failUserOpSig";
        }
    }

    function _enableValidatorSuccessPreCondition() internal {
        MockValidator(address(enabledValidator)).sudoSetSuccess(true);
        mockValidator.sudoSetValidSig(abi.encodePacked("enableSig"));
    }

    function _enablePermissionSuccessPreCondition() internal {
        MockPolicy(address(permissionConfig.policies[0])).sudoSetValidSig(
            address(kernel), bytes32(bytes4(0xdeadbeef)), "policy1"
        );
        MockPolicy(address(permissionConfig.policies[1])).sudoSetValidSig(
            address(kernel), bytes32(bytes4(0xdeadbeef)), "policy2"
        );
        MockSigner(address(permissionConfig.signer)).sudoSetValidSig(
            address(kernel), bytes32(bytes4(0xdeadbeef)), abi.encodePacked("userOpSig")
        );
        mockValidator.sudoSetValidSig(abi.encodePacked("enableSig"));
    }

    function _prepareValidatorEnableUserOp() internal returns (PackedUserOperation memory op) {
        _rootValidatorSuccessPreCondition();
        _enableValidatorSuccessPreCondition();
        uint192 encodedAsNonceKey = ValidatorLib.encodeAsNonceKey(
            ValidationMode.unwrap(VALIDATION_MODE_ENABLE),
            ValidationType.unwrap(VALIDATION_TYPE_VALIDATOR),
            bytes20(address(enabledValidator)),
            0
        );
        op = PackedUserOperation({
            sender: address(kernel),
            nonce: entrypoint.getNonce(address(kernel), encodedAsNonceKey),
            initCode: hex"",
            callData: abi.encodeWithSelector(
                kernel.execute.selector,
                ExecLib.encodeSimpleSingle(),
                ExecLib.encodeSingle(address(callee), 0, abi.encodeWithSelector(callee.setValue.selector, 123))
                ),
            accountGasLimits: bytes32(abi.encodePacked(uint128(1000000), uint128(1000000))),
            preVerificationGas: 1000000,
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
            paymasterAndData: hex"",
            signature: encodeEnableSignature(
                validatorConfig.hook,
                validatorConfig.validatorData,
                validatorConfig.hookData,
                abi.encodePacked(kernel.execute.selector),
                getEnableSig(true),
                getValidatorSig(true)
                )
        });
    }

    function _preparePermissionEnableUserOp() internal returns (PackedUserOperation memory op) {
        uint192 encodedAsNonceKey = ValidatorLib.encodeAsNonceKey(
            ValidationMode.unwrap(VALIDATION_MODE_ENABLE),
            ValidationType.unwrap(VALIDATION_TYPE_PERMISSION),
            bytes20(bytes4(0xdeadbeef)), // permission id
            0
        );
        assertEq(kernel.currentNonce(), 2);
        _rootValidatorSuccessPreCondition();
        _enablePermissionSuccessPreCondition();
        op = PackedUserOperation({
            sender: address(kernel),
            nonce: entrypoint.getNonce(address(kernel), encodedAsNonceKey),
            initCode: hex"",
            callData: abi.encodeWithSelector(
                kernel.execute.selector,
                ExecLib.encodeSimpleSingle(),
                ExecLib.encodeSingle(address(callee), 0, abi.encodeWithSelector(callee.setValue.selector, 123))
                ),
            accountGasLimits: bytes32(abi.encodePacked(uint128(1000000), uint128(1000000))),
            preVerificationGas: 1000000,
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
            paymasterAndData: hex"",
            signature: encodeEnableSignature(
                IHook(address(0)),
                encodePermissionsEnableData(),
                abi.encodePacked("world"),
                abi.encodePacked(kernel.execute.selector),
                abi.encodePacked("enableSig"),
                abi.encodePacked(
                    bytes1(0),
                    bytes8(uint64(7)),
                    "policy1",
                    bytes1(uint8(1)),
                    bytes8(uint64(7)),
                    "policy2",
                    bytes1(0xff),
                    "userOpSig"
                )
                )
        });
    }

    function testValidateUserOpSuccessValidatorEnableMode() external whenInitialized {
        vm.deal(address(kernel), 1e18);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _prepareValidatorEnableUserOp();
        entrypoint.handleOps(ops, payable(address(0xdeadbeef)));
        ValidationManager.ValidationConfig memory config =
            kernel.validatorConfig(ValidatorLib.validatorToIdentifier(enabledValidator));
        assertEq(config.nonce, 2);
        assertEq(address(config.hook), address(1));
        assertEq(kernel.currentNonce(), 3);
    }

    function encodePermissionsEnableData() internal returns (bytes memory) {
        bytes[] memory permissions = new bytes[](permissionConfig.policies.length + 1);
        for (uint256 i = 0; i < permissions.length - 1; i++) {
            permissions[i] = abi.encodePacked(
                PolicyData.unwrap(ValidatorLib.encodePolicyData(false, false, address(permissionConfig.policies[i]))),
                permissionConfig.policyData[i]
            );
        }
        permissions[permissions.length - 1] = abi.encodePacked(
            PolicyData.unwrap(ValidatorLib.encodePolicyData(false, false, address(permissionConfig.signer))),
            permissionConfig.signerData
        );
        return abi.encode(permissions);
    }

    function testValidateUserOpSuccessPermissionEnableMode() external whenInitialized {
        vm.deal(address(kernel), 1e18);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _preparePermissionEnableUserOp();
        entrypoint.handleOps(ops, payable(address(0xdeadbeef)));
        assertEq(kernel.currentNonce(), 3);
    }

    function testActionInstall() external {}

    function testActionInstallWithHook() external {}

    function testFallbackInstall() external {}

    function testFallbackInstallWithHook() external {}

    function testExecutorInstall() external {}

    function testExecutorInstallWithHook() external {}

    function testSignatureValidator() external {}

    function testSignaturePermission() external {}

    function testSignatureRoot() external {}

    function testEnablePermission() external {}

    function testEnableValidator() external {}

    // #2 permission standard
    // - root : validator, enable : permission
    // - root : validator, enable : permission
    // - root : permission, enable : permission
    // - root : permission, enable : validator
}
