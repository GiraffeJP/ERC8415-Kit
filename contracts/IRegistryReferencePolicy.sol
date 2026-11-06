// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Whether a register guarantees a canonical, nonzero registry reference.
/// @notice Optional and separate from `IProjectionSettlement` on purpose: a
/// register that does not implement it is still conforming, and the settlement
/// interface identifier does not move because this exists.
///
/// The problem it answers is one a collateral or escrow contract cannot answer
/// for itself. Such a contract has to enforce one registry reference per live
/// asset, or the same asset can be pledged twice. It can index whatever
/// `registryReference` the entry carries, but a verification profile may allow
/// that field to be zero or non-canonical, and nothing on chain tells the
/// contract which it is dealing with. Indexing a zero reference silently
/// collapses every such asset onto one key.
///
/// A register that advertises this interface and answers `true` has promised
/// that every entry it holds carries a nonzero reference, so the key an
/// instrument indexes is meaningful. The promise stops there. Canonical form
/// beyond "nonzero" - how a reference is spelled, which registrar namespace it
/// belongs to, whether two spellings denote one asset - is profile-defined,
/// and this interface deliberately does not define it.
///
/// This does not move the one-reference-per-live-asset rule onto the register.
/// Collateral and escrow contracts still keep their own index; this only tells
/// them whether the thing they are indexing is worth indexing.
///
/// Discovery runs from the settlement contract an instrument already holds:
/// call `projection()` on it for the register address, call
/// `supportsInterface(0x42ae525a)` on that address, and read
/// `canonicalRegistryReference()` only if it answers true. The property is the
/// register's, so a settlement contract does not advertise this interface on
/// the register's behalf. A register that does not advertise it gives no
/// guarantee at all, which is the same position as one that advertises it and
/// answers false: the instrument must treat every `registryReference` as
/// possibly zero and index accordingly.
interface IRegistryReferencePolicy {
    /// @notice True when every entry in this register is guaranteed to carry a
    /// nonzero `registryReference`, fixed for the life of the deployment.
    function canonicalRegistryReference() external view returns (bool guaranteed);
}
