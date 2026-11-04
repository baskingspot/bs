extern __thread int tls_ie_var __attribute__((tls_model("initial-exec")));
int c_tls_ie2(void) { return tls_ie_var + 1; }
