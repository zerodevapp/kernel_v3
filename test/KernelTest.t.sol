pragma solidity ^0.8.0;

import "src/Kernel.sol";
import "forge-std/Test.sol";
import "src/mock/MockValidator.sol";
import "src/core/PermissionManager.sol";
import "./erc4337Util.sol";

contract SimpleProxy {
    address immutable target;

    constructor(address _target) {
        target = _target;
    }

    receive() external payable {
        (bool success,) = target.delegatecall("");
        require(success, "delegatecall failed");
    }

    fallback(bytes calldata) external payable returns (bytes memory) {
        (bool success, bytes memory ret) = target.delegatecall(msg.data);
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

contract KernelTest is Test {
    MockValidator validator;
    Kernel kernel;
    IEntryPoint entrypoint;
    MockCallee callee;

    modifier whenInitialized() {
        ValidatorIdentifier vId = ValidatorLib.validatorToIdentifier(validator);
        kernel.initialize(vId, IHook(address(0)), hex"", hex"");
        _;
    }

    function setUp() public {
        entrypoint = IEntryPoint(EntryPointLib.deploy());
        validator = new MockValidator();
        Kernel impl = new Kernel(entrypoint);
        callee = new MockCallee();
        kernel = Kernel(payable(address(new SimpleProxy(address(impl)))));
    }

    function testInitialize() external {
        ValidatorIdentifier vId = ValidatorLib.validatorToIdentifier(validator);
        kernel.initialize(vId, IHook(address(0)), hex"", hex"");
        assertTrue(kernel.rootValidator() == vId);
        ValidationManager.ValidatorConfig memory config;
        (config.group, config.nonce, config.validFrom, config.validUntil, config.hook) = kernel.validatorConfig(vId);
        assertEq(config.group, bytes4(0));
        assertEq(config.nonce, 0);
        assertEq(config.validFrom, 0);
        assertEq(config.validUntil, 0);
        assertEq(address(config.hook), address(1));
        assertEq(validator.isInitialized(address(kernel)), true);
    }

    // scenario
    function testValidateUserOpSuccess() external whenInitialized {
        vm.deal(address(kernel), 1e18);
        uint256 count = validator.count();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = PackedUserOperation({
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
            signature: hex""
        });
        validator.sudoSetSuccess(true);
        entrypoint.handleOps(ops, payable(address(0xdeadbeef)));
        assertEq(validator.count(), count + 1);
    }

    function testValidateUserOpFail() external whenInitialized {
        vm.deal(address(kernel), 1e18);
        uint256 count = validator.count();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = PackedUserOperation({
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
            signature: hex""
        });
        validator.sudoSetSuccess(false);
        vm.expectRevert();
        entrypoint.handleOps(ops, payable(address(0xdeadbeef)));
        assertEq(validator.count(), count);
    }
}