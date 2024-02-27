pragma solidity ^0.8.0;

import {IValidator} from "../interfaces/IERC7579Modules.sol";
import {
    Group,
    GroupId,
    PassFlag,
    ValidationType,
    ValidationId,
    ValidationMode,
    PermissionData,
    PermissionId
} from "../types/Types.sol";

library ValidatorLib {
    function parseGroup(Group group) internal pure returns (GroupId groupId, PassFlag passFlag) {
        assembly {
            groupId := group
            passFlag := shl(16, group)
        }
    }

    function encodeGroup(GroupId groupId, PassFlag passFlag) internal pure returns (Group group) {
        assembly {
            group := or(groupId, shr(16, passFlag))
        }
    }

    function encodeFlag(bool skipUserOp, bool skipSignature) internal pure returns (PassFlag flag) {
        assembly {
            if skipUserOp { flag := 0x0001000000000000000000000000000000000000000000000000000000000000 }
            if skipSignature { flag := or(flag, 0x0002000000000000000000000000000000000000000000000000000000000000) }
        }
    }

    function encodeAsNonce(bytes1 mode, bytes1 vType, bytes20 ValidationIdWithoutType, uint16 nonceKey, uint64 nonce)
        internal
        pure
        returns (uint256 res)
    {
        assembly {
            res := nonce
            res := or(res, shl(64, nonceKey))
            res := or(res, shr(16, ValidationIdWithoutType))
            res := or(res, shr(8, vType))
            res := or(res, mode)
        }
    }

    function encodeAsNonceKey(bytes1 mode, bytes1 vType, bytes20 ValidationIdWithoutType, uint16 nonceKey)
        internal
        pure
        returns (uint192 res)
    {
        assembly {
            res := or(nonceKey, shr(80, ValidationIdWithoutType))
            res := or(res, shr(72, vType))
            res := or(res, shr(64, mode))
        }
    }

    function decodeNonce(uint256 nonce)
        internal
        pure
        returns (ValidationMode mode, ValidationType vType, ValidationId identifier)
    {
        // 2bytes mode (1byte currentMode, 1byte type)
        // 21bytes identifier
        // 1byte mode  | 1byte type | 20bytes identifierWithoutType | 2byte nonceKey | 8byte nonce == 32bytes
        assembly {
            mode := nonce
            vType := shl(8, nonce)
            identifier := shl(8, nonce)
            switch shr(248, identifier)
            case 0x0000000000000000000000000000000000000000000000000000000000000002 {
                identifier := and(identifier, 0xffffffffff000000000000000000000000000000000000000000000000000000)
            }
        }
    }

    function decodePermissionData(PermissionData data) internal pure returns (PassFlag flag, IValidator validator) {
        assembly {
            flag := data
            validator := shr(80, data)
        }
    }

    function validatorToIdentifier(IValidator validator) internal pure returns (ValidationId vId) {
        assembly {
            vId := 0x0100000000000000000000000000000000000000000000000000000000000000
            vId := or(vId, shl(88, validator))
        }
    }

    function getType(ValidationId validator) internal pure returns (ValidationType vType) {
        assembly {
            vType := validator
        }
    }

    function getValidator(ValidationId validator) internal pure returns (IValidator v) {
        assembly {
            v := shr(88, validator)
        }
    }

    function getPermissionId(ValidationId validator) internal pure returns (PermissionId id) {
        assembly {
            id := shl(8, validator)
        }
    }

    function getPermissionValidator(PermissionData data) internal pure returns (IValidator vId) {
        assembly {
            vId := shr(80, data)
        }
    }

    function getPermissionSkip(PermissionData data) internal pure returns (PassFlag flag) {
        assembly {
            flag := data
        }
    }
}