__thread int tls_gd = 7;
static __thread int tls_ld = 11;
extern __thread int tls_ie_var;
__thread int tls_ie_var = 3;
int c_tls(void) { tls_ld += 1; return tls_gd * 100 + tls_ld; }
int c_tls_ie(void) { return tls_ie_var; }
