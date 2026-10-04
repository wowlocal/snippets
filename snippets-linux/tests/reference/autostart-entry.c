/* Independent native desktop-entry parser/launcher, public temporary argv only. */
#define _GNU_SOURCE
#include <gio/gdesktopappinfo.h>
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
static void child(GDesktopAppInfo *info,GPid pid,void *data){(void)info;*(GPid *)data=pid;}
int main(int argc,char **argv){
    if(argc==3&&!strcmp(argv[1],"--launch")){
        GDesktopAppInfo *info=g_desktop_app_info_new_from_filename(argv[2]);assert(info);
        GPid pid=0;GError *error=NULL;
        int ok=g_desktop_app_info_launch_uris_as_manager(info,NULL,NULL,G_SPAWN_DO_NOT_REAP_CHILD,NULL,NULL,child,&pid,&error);
        if(!ok){fprintf(stderr,"native fixture launch failed\n");g_clear_error(&error);g_object_unref(info);return 2;}
        assert(pid>0);int status;assert(waitpid(pid,&status,0)==pid);g_spawn_close_pid(pid);g_object_unref(info);
        return WIFEXITED(status)?WEXITSTATUS(status):3;
    }
    assert(argc==2&&!strcmp(argv[1],"--background"));
    const char *path=getenv("SNIPPETS_STARTUP_PROOF");assert(path);
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(fd>=0);
    FILE *file=fdopen(fd,"w");assert(file);assert(fprintf(file,"%s\n%s\n",argv[0],argv[1])>0);assert(fclose(file)==0);return 0;
}
