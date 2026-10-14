/*
 *  fixture-agent.c — 合成「终端 AI Agent」进程。
 *
 *  Owner: master-controller
 *
 *  为什么是编译出来的二进制，而不是改名的脚本或 /bin/bash 副本：
 *   1) 平台签名（platform csflag）的系统二进制被复制到别处执行会被内核 SIGKILL，
 *      实测 `cp /bin/bash ./claude` 直接 Killed: 9；
 *   2) 脚本的 p_comm 是解释器名（sh/bash），命不中「进程名 == claude」这条签名策略。
 *  自己编译的二进制由链接器 ad-hoc 签名，p_comm 取可执行文件名，即 "claude"。
 *
 *  它真实 fork 子进程跑真实命令，走的是内核 exec / proc_pidinfo / KERN_PROCARGS2 /
 *  FSEvents 的生产路径；被合成的只有「这个进程叫 claude」这一层身份。
 *
 *  用法：claude <持续秒数> <工作目录> [<被测仓库目录>]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void run(const char *cmd) {
    int rc = system(cmd);
    (void)rc; /* 命令失败本身就是要被审计到的事实 */
}

int main(int argc, char **argv) {
    const int duration = argc > 1 ? atoi(argv[1]) : 45;
    const char *work = argc > 2 ? argv[2] : ".";
    /* 被测仓库路径由调用方给，不写死个人绝对路径——换台机器夹具会静默不跑。 */
    const char *repo = argc > 3 && argv[3][0] != '\0' ? argv[3] : work;
    char repo_cmd[1024];
    snprintf(repo_cmd, sizeof repo_cmd,
             "cd %s && git status --porcelain >/dev/null 2>&1", repo);
    if (chdir(work) != 0) {
        perror("chdir");
        return 1;
    }
    const time_t deadline = time(NULL) + duration;
    for (int i = 1; time(NULL) < deadline; i++) {
        /* 只读命令：Agent 的高频动作 */
        run(repo_cmd);
        run("ls -la /tmp >/dev/null 2>&1");
        run("find . -maxdepth 1 -name '*.md' >/dev/null 2>&1");
        /* 写文件：文件追踪与项目地图也拿到真实事实 */
        FILE *f = fopen("notes.md", "a");
        if (f) { fprintf(f, "entry-%d\n", i); fclose(f); }
        /* 每 4 轮**整体重写**一次，让文件变短。
         *
         * 为什么需要：只追加的话，Before/After 的「改前内容」在真机上永远只表现为
         * context 行，`removed` 渲染路径**一条真机证据都拿不到**——
         * 而它正是需求③ 的另一半（删了哪些行）。
         * 保留 `line-1` 是有意的：它由 fixture-agent.sh 在 Agent 启动前写入，
         * 能一直活着就说明「改前版本」确实是上一轮观测到的那份内容，而不是当场读盘凑出来的。
         */
        if (i % 4 == 0) {
            FILE *g = fopen("notes.md", "w");
            if (g) { fprintf(g, "line-1\nreset-%d\n", i); fclose(g); }
        }
        /* 破坏性命令：走风险层的真实判定路径。
         *
         * 为什么不是 `rm -rf`：项目根会被推导成「允许写入根」，
         * `DFOHomeSubtreeDeletionRule` / `DFOOutsideProjectWriteRule` 都有
         * `guard !window.isWithinAllowedWriteRoots(path)` 护栏 ⇒
         * **授权边界内的删除按设计就不该出 risk_events**，拿它验证只会误判成「规则坏了」。
         * `chmod -R 777` 走的是结构式、只看命令文本的
         * `risk.command.recursive-permission-broadening`（HIGH），且只作用于本夹具目录。
         *
         * 为什么要拖到 4 秒：命令审计靠轮询进程快照，3 秒间隔对 30–50 ms 的短命命令
         * 捕获率约 1–2%（见 01-架构/真机验证-命令审计与检出.md）。真实 Agent 的 Bash 工具
         * 本来就是 `sh -c "<一条命令>"` 的形态，这里加一个 sleep 只是让**被采到的概率**变高，
         * 不改变「谁来执行、执行了什么」这两件事。 */
        if (i == 3) run("chmod -R 777 ./junk; sleep 4");
        sleep(2);
    }
    return 0;
}
