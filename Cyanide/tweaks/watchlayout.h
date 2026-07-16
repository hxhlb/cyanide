//
//  watchlayout.h
//  RemoteCall-only vertically scrolling Apple Watch icon layout.
//

#ifndef watchlayout_h
#define watchlayout_h

#import <stdbool.h>

bool watchlayout_apply_in_session(void);
bool watchlayout_stop_in_session(void);
bool watchlayout_has_cached_state(void);
void watchlayout_forget_remote_state(void);

#endif /* watchlayout_h */
