// App-private FIFO admission. A held file lock, never a PID, proves a live
// request. The helper still inherits only the original worker.lock on fd 3.
#include <sys/stdio.h>
typedef struct { int directory, ticket, gate; char name[NAME_MAX+1]; } FairLease;
static void FairInit(FairLease *lease) { memset(lease,0,sizeof(*lease));lease->directory=lease->ticket=lease->gate=-1; }
static uid_t FairUID(void) {
#ifdef VZ_FAIR_LEASE_NATIVE_FIXTURE
    return geteuid();
#else
    return 501;
#endif
}
static gid_t FairGID(void) {
#ifdef VZ_FAIR_LEASE_NATIVE_FIXTURE
    return getegid();
#else
    return 501;
#endif
}
static BOOL FairName(const char *name) {
    if(strlen(name)!=45 || strncmp(name,".ticket-",8) || name[28]!='-')return NO;
    for(unsigned i=8;i<28;i++)if(name[i]<'0'||name[i]>'9')return NO;
    for(unsigned i=29;i<45;i++)if(!((name[i]>='0'&&name[i]<='9')||(name[i]>='a'&&name[i]<='f')))return NO;
    return YES;
}
static BOOL FairPendingName(const char *name) {
    if(strlen(name)!=25||strncmp(name,".pending-",9))return NO;
    for(unsigned i=9;i<25;i++)if(!((name[i]>='0'&&name[i]<='9')||(name[i]>='a'&&name[i]<='f')))return NO;
    return YES;
}
static BOOL FairPolicy(const struct stat *s) {
    return S_ISREG(s->st_mode)&&s->st_uid==FairUID()&&s->st_gid==FairGID()&&
           (s->st_mode&07777)==0600&&s->st_nlink==1&&s->st_size==0;
}
static void FairUnlink(int directory,int fd,const char *name) {
    struct stat a,b;
    if(!fstat(fd,&a)&&!fstatat(directory,name,&b,AT_SYMLINK_NOFOLLOW)&&
       a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&FairPolicy(&a)&&FairPolicy(&b))
        unlinkat(directory,name,0);
}
static void FairRelease(FairLease *lease) {
    if(lease->ticket>=0) {
        if(lease->directory>=0&&lease->name[0])FairUnlink(lease->directory,lease->ticket,lease->name);
        close(lease->ticket);
    }
    if(lease->directory>=0)close(lease->directory);
    if(lease->gate>=0)close(lease->gate);
    FairInit(lease);
}
static BOOL FairPublish(FairLease *lease,uint64_t deadline) {
    struct stat value;
    uint64_t nonce=0;char pending[NAME_MAX+1]={0};
    for(unsigned attempt=0;attempt<8&&Before(deadline);attempt++) {
        arc4random_buf(&nonce,sizeof(nonce));
        snprintf(pending,sizeof(pending),".pending-%016llx",(unsigned long long)nonce);
        // The queue gate excludes scanners across creation and publication.
        // O_EXLOCK also ensures this open returns with its ticket lock held.
        lease->ticket=openat(lease->directory,pending,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC|O_EXLOCK|O_NONBLOCK,0600);
        if(lease->ticket>=0||errno!=EEXIST)break;
    }
    if(lease->ticket<0)return NO;
    strlcpy(lease->name,pending,sizeof(lease->name));
    if((geteuid()==0&&fchown(lease->ticket,FairUID(),FairGID()))||
       fstat(lease->ticket,&value)||!FairPolicy(&value)||flock(lease->ticket,LOCK_EX|LOCK_NB))return NO;
    uint64_t stamp=Now();if(!stamp||!Before(deadline))return NO;
    char published[NAME_MAX+1];
    snprintf(published,sizeof(published),".ticket-%020llu-%016llx",(unsigned long long)stamp,(unsigned long long)nonce);
    // Publish only after owning its lock. An unpublished request cannot be
    // mistaken for an abandoned ticket. EXCL never replaces another request.
    if(renameatx_np(lease->directory,pending,lease->directory,published,RENAME_EXCL))return NO;
    strlcpy(lease->name,published,sizeof(lease->name));return YES;
}
static BOOL FairCreate(int work,uint64_t deadline,FairLease *lease) {
    if(!Before(deadline))return NO;
    BOOL created=mkdirat(work,"worker-queue-v2",0700)==0;
    if(!created&&errno!=EEXIST)return NO;
    lease->directory=openat(work,"worker-queue-v2",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(lease->directory<0)return NO;
    if(created&&geteuid()==0&&fchown(lease->directory,FairUID(),FairGID()))return NO;
    struct stat value;
    if(fstat(lease->directory,&value)||!S_ISDIR(value.st_mode)||value.st_uid!=FairUID()||
       value.st_gid!=FairGID()||(value.st_mode&07777)!=0700)return NO;
    created=YES;
    lease->gate=openat(lease->directory,"queue.lock",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(lease->gate<0&&errno==EEXIST) {
        created=NO;lease->gate=openat(lease->directory,"queue.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    }
    if(lease->gate<0||(created&&geteuid()==0&&fchown(lease->gate,FairUID(),FairGID()))||
       fstat(lease->gate,&value)||!FairPolicy(&value))return NO;
    // Metadata-only critical section. Never held during conversion, worker
    // lock waiting or native calls, and never inherited by the CPU helper.
    while(Before(deadline)) {
        if(!flock(lease->gate,LOCK_EX|LOCK_NB)) {
            BOOL okay=FairPublish(lease,deadline);int error=errno;
            if(flock(lease->gate,LOCK_UN)){okay=NO;error=errno;}
            errno=error;return okay;
        }
        if(errno!=EWOULDBLOCK&&errno!=EAGAIN&&errno!=EINTR)return NO;
        Pause(deadline);
    }
    return NO;
}
// 1=head, 0=older live request, -1=policy/I/O/deadline failure.
static int FairScanTurn(FairLease *lease,uint64_t deadline) {
    if(!Before(deadline))return -1;
    int copy=openat(lease->directory,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(copy<0)return -1;
    DIR *stream=fdopendir(copy);if(!stream){close(copy);return -1;}
    struct dirent *entry;unsigned visited=0;int answer=1;
    while(1) {
        errno=0;entry=readdir(stream);
        if(!entry){if(errno)answer=-1;break;}
        if(!Before(deadline)||++visited>256){answer=-1;break;}
        BOOL published=FairName(entry->d_name),pending=FairPendingName(entry->d_name);
        if((!published&&!pending)||!strcmp(entry->d_name,lease->name))continue;
        int older=openat(lease->directory,entry->d_name,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
        if(older<0){if(errno==ENOENT)continue;answer=-1;break;}
#ifdef VZ_FAIR_SCAN_REPRO
        VZ_FAIR_SCAN_REPRO(lease->directory,entry->d_name);
#endif
        struct stat value;
        if(fstat(older,&value)){close(older);answer=-1;break;}
        if(!FairPolicy(&value)) {
            // Another exact lease can unlink after our open but before stat.
            // A detached, otherwise strictly owned inode is no longer a queue
            // member only when this precise linked name also returns ENOENT.
            struct stat linked;errno=0;
            BOOL departed=S_ISREG(value.st_mode)&&value.st_uid==FairUID()&&
                value.st_gid==FairGID()&&(value.st_mode&07777)==0600&&
                value.st_size==0&&value.st_nlink==0&&
                fstatat(lease->directory,entry->d_name,&linked,AT_SYMLINK_NOFOLLOW)<0&&errno==ENOENT;
            close(older);if(departed)continue;answer=-1;break;
        }
        int rc=flock(older,LOCK_EX|LOCK_NB),error=rc?errno:0;
        if(!rc) {
            // The original open-file-description no longer owns this ticket.
            // Cleanup holds its lock and checks the linked inode identity.
            FairUnlink(lease->directory,older,entry->d_name);close(older);continue;
        }
        close(older);
        if(error==EWOULDBLOCK||error==EAGAIN) {
            // Clean unlocked tickets even from an older boot's future stamp.
            // Only a live, published older request blocks admission.
            if(published&&strcmp(entry->d_name,lease->name)<0){answer=0;break;}
            continue;
        }
        if(error==EINTR){answer=0;break;}
        answer=-1;break;
    }
    closedir(stream);return answer;
}
static int FairHasTurn(FairLease *lease,uint64_t deadline) {
    if(!Before(deadline))return -1;
    if(flock(lease->gate,LOCK_EX|LOCK_NB))
        return errno==EWOULDBLOCK||errno==EAGAIN||errno==EINTR?0:-1;
    int answer=FairScanTurn(lease,deadline),error=errno;
    if(flock(lease->gate,LOCK_UN)){answer=-1;error=errno;}
    errno=error;return answer;
}
