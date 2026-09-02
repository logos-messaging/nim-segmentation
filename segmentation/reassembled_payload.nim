## A payload successfully reconstructed from a segment set.
##
## Named for what it holds rather than `...Result`: the API already returns
## `Result[Opt[ReassembledPayload], string]`, and two senses of "result" in one
## signature is one too many.

{.push raises: [].}

type ReassembledPayload* = object
  payload*: seq[byte]
  originalPayloadHash*: seq[byte]

func init*(
    T: type ReassembledPayload, payload: seq[byte], originalPayloadHash: seq[byte]
): T =
  return T(payload: payload, originalPayloadHash: originalPayloadHash)

{.pop.}
