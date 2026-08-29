"""Merkle tree compatible with OpenZeppelin MerkleProof (sorted-pair / commutative keccak256).

leaf(k, account, amount) = keccak256(keccak256(abi.encode(uint256 k, address account, uint256 amount)))
parent(a, b)             = keccak256(min(a,b) || max(a,b))
Leaves are sorted ascending before building. Odd nodes are promoted unchanged (no duplication).
"""
from keccak import keccak256


def abi_encode_leaf(k: int, account: str, amount_sat: int) -> bytes:
    a = bytes.fromhex(account.lower().replace("0x", ""))
    assert len(a) == 20, account
    return k.to_bytes(32, "big") + (b"\x00" * 12 + a) + amount_sat.to_bytes(32, "big")


def leaf_hash(k: int, account: str, amount_sat: int) -> bytes:
    return keccak256(keccak256(abi_encode_leaf(k, account, amount_sat)))


def _parent(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b) if a < b else keccak256(b + a)


class MerkleTree:
    def __init__(self, leaves):
        assert len(leaves) > 0, "empty tree"
        self.leaves = sorted(set(leaves))
        assert len(self.leaves) == len(leaves), "duplicate leaves"
        self.levels = [list(self.leaves)]
        while len(self.levels[-1]) > 1:
            cur = self.levels[-1]
            nxt = []
            for i in range(0, len(cur), 2):
                if i + 1 < len(cur):
                    nxt.append(_parent(cur[i], cur[i + 1]))
                else:
                    nxt.append(cur[i])  # promote
            self.levels.append(nxt)

    @property
    def root(self) -> bytes:
        return self.levels[-1][0]

    def proof(self, leaf: bytes):
        idx = self.leaves.index(leaf)
        out = []
        for level in self.levels[:-1]:
            sib = idx ^ 1
            if sib < len(level):
                out.append(level[sib])
            idx //= 2
        return out


def verify(proof, root: bytes, leaf: bytes) -> bool:
    h = leaf
    for p in proof:
        h = _parent(h, p)
    return h == root


if __name__ == "__main__":
    # tiny self-test
    ls = [leaf_hash(0, "0x" + ("%040x" % i), (5 + i) * 10**8) for i in range(1, 8)]
    t = MerkleTree(ls)
    for l in ls:
        assert verify(t.proof(l), t.root, l)
    assert not verify(t.proof(ls[0]), t.root, ls[1])
    print("merkle self-test OK, root", t.root.hex())
