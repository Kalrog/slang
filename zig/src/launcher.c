/* slang.exe on Windows: the command line lives in slang.dll (src/lib.zig),
 * next to which native extensions link. slang_main reads the process's own
 * UTF-16 arguments, so argv here is only passed along. */
int slang_main(int argc, char **argv);

int main(int argc, char **argv) {
    return slang_main(argc, argv);
}
