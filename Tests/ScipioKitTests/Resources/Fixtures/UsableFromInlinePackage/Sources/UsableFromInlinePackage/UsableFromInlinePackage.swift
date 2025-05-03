import ClangModule
#if os(iOS)
import ClangModuleForIOS
#elseif os(macOS)
import ClangModuleForMacOS
#endif

@usableFromInline
func sample() {
    this_is_c_function()
#if os(iOS)
    this_is_c_function_for_ios()
#elseif os(macOS)
    this_is_c_function_for_macos()
#endif
}
