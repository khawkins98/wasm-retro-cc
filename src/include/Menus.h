#ifndef MENUS_H
#define MENUS_H

#include "Types.h"

typedef int16_t MenuID;
typedef void *MenuHandle;  /* opaque */

extern void       InitMenus(void);
extern void       DrawMenuBar(void);
extern void       ClearMenuBar(void);
extern MenuHandle GetMenu(MenuID resourceID);
extern void       InsertMenu(MenuHandle theMenu, MenuID beforeID);
extern void       AppendMenu(MenuHandle theMenu, const unsigned char *data);
extern int32_t    MenuSelect(Point startPt);
extern void       HiliteMenu(MenuID menuID);
extern void       DeleteMenu(MenuID menuID);
extern void       DisposeMenu(MenuHandle theMenu);
extern void       EnableItem(MenuHandle theMenu, int16_t item);
extern void       DisableItem(MenuHandle theMenu, int16_t item);
extern void       CheckItem(MenuHandle theMenu, int16_t item, Boolean checked);

#endif /* MENUS_H */
