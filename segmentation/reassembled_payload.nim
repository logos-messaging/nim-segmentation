## A payload successfully reconstructed from a segment set.
##
## Named for what it holds rather than `...Result`: the API already returns
## `Result[Opt[ReassembledPayload], string]`, and two senses of "result" in one
## signature is one too many.

{.push raises: [].}

type ReassembledPayload* = object ## A payload rebuilt from a complete segment set.
  payload*: seq[byte]
  originalPayloadHash*: seq[byte]

func init*(
    T: type ReassembledPayload, payload: seq[byte], originalPayloadHash: seq[byte]
): T =
  ## `originalPayloadHash` is the set's Keccak256, already verified against
  ## `payload` by the time a caller sees this.
  return T(payload: payload, originalPayloadHash: originalPayloadHash)

{.pop.}
