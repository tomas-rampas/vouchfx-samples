// Referenced by ../ledger.e2e.yaml step 'assert-arithmetic-invariant' via
// `file:` (vouchfx's script.csharp step type, `file` field). Resolved relative
// to ledger.e2e.yaml's own directory and read once at compile time — spliced
// into the compiled submission exactly as an inline `code:` body would be
// (same trust boundary, same absence of {placeholder}/${secret:...}
// substitution; see vouchfx docs/02 §5.6). This is the same assertion the
// suite ran as inline `code:` before this sample demonstrated the external-
// file alternative — moved here once it earned its own file.
//
// closing_balance was captured as a JSON-RPC result value (a JSON number), so
// it comes back through Vars as its JSON text ("475"), not a native int — see
// the community provider's capture implementation (RpcJsonRpc_Helpers
// .ExecuteAsync: a non-string JsonValue capture falls back to
// val.ToJsonString()). A thrown exception here is caught by the
// script.csharp scaffolding and recorded as Verdict.Fail (never an unhandled
// crash of the whole suite) — see ScriptCsharpProvider.Emit.
var closingBalance = int.Parse((string)Vars["closing_balance"]);
const int expectedBalance = 500 - 25;
if (closingBalance != expectedBalance)
{
    throw new Exception($"arithmetic invariant violated: expected closing balance {expectedBalance} (500 deposit - 25 chargeback), got {closingBalance}");
}
