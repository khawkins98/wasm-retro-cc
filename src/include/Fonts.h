#ifndef FONTS_H
#define FONTS_H

#include "Types.h"

/* System font IDs */
#define systemFont  0
#define applFont    1
#define newYork     2
#define geneva      3
#define monaco      4
#define venice      5
#define london      6
#define athens      7
#define sanFran     8
#define toronto     9
#define cairo       11
#define losAngeles  12

extern void InitFonts(void);
extern void GetFontName(int16_t familyID, unsigned char *name);
extern void GetFNum(const unsigned char *name, int16_t *familyID);
extern int16_t RealFont(int16_t fontNum, int16_t size);

#endif /* FONTS_H */
