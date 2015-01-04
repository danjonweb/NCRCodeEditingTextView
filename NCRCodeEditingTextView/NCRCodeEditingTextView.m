#import "NCRCodeEditorTextView.h"
#import "NoodleLineNumberView.h"
#import "SFBPopover.h"

// Autocomplete
#define MAX_RESULTS 10

#define HIGHLIGHT_FILL_COLOR [NSColor colorWithCalibratedRed:0.27 green:0.41 blue:1.0 alpha:1.0]
#define HIGHLIGHT_STROKE_COLOR [NSColor colorWithCalibratedRed:0.27 green:0.41 blue:1.0 alpha:1.0]
#define HIGHLIGHT_RADIUS 0.0
#define INTERCELL_SPACING NSMakeSize(20.0, 0.0)

#define POPOVER_WIDTH 170.0
#define POPOVER_PADDING 0.0
#define POPOVER_APPEARANCE NSAppearanceNameVibrantLight
#define POPOVER_FONT [NSFont systemFontOfSize:12.0]
#define POPOVER_TEXTCOLOR [NSColor blackColor]

// Syntax highlighting
#define DEFAULT_FONT [NSFont userFixedPitchFontOfSize:[NSFont systemFontSize]]

#define kComponentsKey @"components"
#define kAutocompleteKey @"autocomplete"
#define kTypeKeywords @"Keywords"
#define kTypeBlockComment @"BlockComment"
#define kTypeLineComment @"SingleLineComment"
#define kTypeString @"String"

#define kTypeKey @"type"
#define kStartKey @"start"
#define kEndKey @"end"
#define kFGColorKey @"foregroundColor"
#define kBGColorKey @"backgroundColor"
#define kEscapeKey @"escape"
#define kBoundaryKey @"boundary"
#define kStringArrayKey @"strings"

#pragma mark - NSColor+String

@implementation NSColor (String)
- (NSString *)stringRepresentation {
    CGFloat components[10];
    
    [self getComponents:components];
    NSMutableString *string = [NSMutableString string];
    for (int i = 0; i < [self numberOfComponents]; i++) {
        [string appendFormat:@"%f ", components[i]];
    }
    [string deleteCharactersInRange:NSMakeRange([string length]-1, 1)]; // trim the trailing space
    return string;
}
+ (NSColor*)colorFromString:(NSString*)string forColorSpace:(NSColorSpace *)colorSpace {
    if (!string) {
        return [NSColor controlBackgroundColor];
    }
    CGFloat components[10];    // doubt any color spaces need more than 10 components
    NSArray *componentStrings = [string componentsSeparatedByString:@" "];
    unsigned long count = [componentStrings count];
    NSColor *color = nil;
    if (count <= 10) {
        for (int i = 0; i < count; i++) {
            components[i] = [[componentStrings objectAtIndex:i] floatValue];
        }
        color = [NSColor colorWithColorSpace:colorSpace components:components count:count];
    }
    return color;
}
@end

#pragma mark - NSObject+PerformBlockAfterDelay

@interface NSObject (PerformBlockAfterDelay)
- (void)performBlock:(void (^)(void))block afterDelay:(NSTimeInterval)delay;
@end
@implementation NSObject (PerformBlockAfterDelay)
- (void)performBlock:(void (^)(void))block afterDelay:(NSTimeInterval)delay {
    [self performSelector:@selector(fireBlockAfterDelay:) withObject:[block copy] afterDelay:delay];
}
- (void)fireBlockAfterDelay:(void (^)(void))block {
    block();
}
@end

#pragma mark - NCRAutocompleteTableRowView

@interface NCRAutocompleteTableRowView : NSTableRowView
@end
@implementation NCRAutocompleteTableRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone) {
        NSRect selectionRect = NSInsetRect(self.bounds, 0.5, 0.5);
        [HIGHLIGHT_STROKE_COLOR setStroke];
        [HIGHLIGHT_FILL_COLOR setFill];
        NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:selectionRect xRadius:HIGHLIGHT_RADIUS yRadius:HIGHLIGHT_RADIUS];
        [selectionPath fill];
        [selectionPath stroke];
    }
}
- (NSBackgroundStyle)interiorBackgroundStyle {
    if (self.isSelected) {
        return NSBackgroundStyleDark;
    } else {
        return NSBackgroundStyleLight;
    }
}
@end

#pragma mark -

@interface NCRAutocompleteTableView : NSTableView
@end
@implementation NCRAutocompleteTableView
- (BOOL)acceptsFirstResponder{
    return NO;
}
@end

#pragma mark - Autocomplete

@interface NCRCodeEditorTextView ()
// Autocomplete
@property (nonatomic, strong) SFBPopover *autocompletePopover;
@property (nonatomic, weak) NCRAutocompleteTableView *autocompleteTableView;
@property (nonatomic, strong) NSMutableArray *matches;
// Used to highlight typed characters and insert text
@property (nonatomic, copy) NSString *substring;
// Used to keep track of when the insert cursor has moved so we
// can close the popover. See didChangeSelection:
@property (nonatomic, assign) NSInteger lastPos;
@property (nonatomic, strong) NSArray *autocompleteWords;
@property (nonatomic, strong) NSDictionary *autocompleteInfo;

// Syntax highlighting
@property (nonatomic, strong) NSMutableDictionary *syntax;
@property (nonatomic, strong) NSDictionary *defaultTextAttributes;
@property (nonatomic, strong) NSArray *keywords;
@property (nonatomic, strong) NSCharacterSet *keywordBoundaryChars;
@end

@implementation NCRCodeEditorTextView

- (void)awakeFromNib {
    // Make a table view with 1 column and enclosing scroll view. It doesn't
    // matter what the frames are here because they are set when the popover
    // is displayed
    NSTableColumn *column1 = [[NSTableColumn alloc] initWithIdentifier:@"text"];
    [column1 setEditable:NO];
    [column1 setWidth:POPOVER_WIDTH - 2 * POPOVER_PADDING];

    NCRAutocompleteTableView *tableView = [[NCRAutocompleteTableView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    [tableView setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleRegular];
    [tableView setBackgroundColor:[NSColor clearColor]];
    [tableView setRowSizeStyle:NSTableViewRowSizeStyleSmall];
    [tableView setIntercellSpacing:INTERCELL_SPACING];
    [tableView setHeaderView:nil];
    [tableView setRefusesFirstResponder:YES];
    [tableView setTarget:self];
    [tableView setDoubleAction:@selector(insert:)];
    [tableView addTableColumn:column1];
    [tableView setDelegate:self];
    [tableView setDataSource:self];
    self.autocompleteTableView = tableView;

    NSScrollView *tableScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [tableScrollView setDrawsBackground:NO];
    [tableScrollView setDocumentView:tableView];
    [tableScrollView setHasVerticalScroller:YES];
    
    /*NSView *contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    [contentView addSubview:tableScrollView];
    
    NSViewController *contentViewController = [[NSViewController alloc] init];
    [contentViewController setView:contentView];*/
    
    self.autocompletePopover = [[SFBPopover alloc] initWithContentView:tableScrollView];
    [self.autocompletePopover setViewMargin:0.0];
    [self.autocompletePopover setBackgroundColor:[NSColor whiteColor]];
    [self.autocompletePopover setBorderWidth:0.0];
    [self.autocompletePopover setArrowWidth:24.0];
    [self.autocompletePopover setArrowHeight:12.0];
    [self.autocompletePopover setCornerRadius:4.0];
    [self.autocompletePopover setAnimates:NO];
    
    NSView *contentView = [[self.autocompletePopover popoverWindow] contentView];
    contentView.wantsLayer = YES;
    contentView.layer.masksToBounds = YES;
    contentView.layer.cornerRadius = self.autocompletePopover.cornerRadius;
    
    /*
    self.autocompletePopover = [[NSPopover alloc] init];
    self.autocompletePopover.appearance = [NSAppearance appearanceNamed:POPOVER_APPEARANCE];
    self.autocompletePopover.animates = NO;
    self.autocompletePopover.delegate = self;
    self.autocompletePopover.contentViewController = contentViewController;
    */
    self.matches = [NSMutableArray array];
    self.lastPos = -1;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didChangeSelection:) name:@"NSTextViewDidChangeSelectionNotification" object:nil];
    
    // Syntax highlighting
    [[self textStorage] setDelegate:self];
    
    [self setRichText:NO];
    [self setFont:DEFAULT_FONT];
    [self setAutomaticQuoteSubstitutionEnabled:NO];
    [self setAutomaticDashSubstitutionEnabled:NO];
    [self setContinuousSpellCheckingEnabled:NO];
    
    NSScrollView *scrollView = [self enclosingScrollView];
    NoodleLineNumberView *lineNumberView = [[NoodleLineNumberView alloc] initWithScrollView:scrollView];
    [scrollView setVerticalRulerView:lineNumberView];
    [scrollView setHasHorizontalRuler:NO];
    [scrollView setHasVerticalRuler:YES];
    [scrollView setRulersVisible:YES];
    
    self.defaultTextAttributes = @{NSFontAttributeName:DEFAULT_FONT, NSForegroundColorAttributeName:[NSColor textColor], NSBackgroundColorAttributeName:[NSColor textBackgroundColor]};
    
    NSMutableCharacterSet *keywordBoundaryChars = [[NSMutableCharacterSet alloc] init];
    [keywordBoundaryChars formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [keywordBoundaryChars formUnionWithCharacterSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    self.keywordBoundaryChars = keywordBoundaryChars;
    
    [self setLanguage:@"javascript"];
}

- (void)keyDown:(NSEvent *)theEvent {
    NSInteger row = self.autocompleteTableView.selectedRow;
    BOOL shouldComplete = YES;
    switch (theEvent.keyCode) {
        case 51:
            // Delete
            [self.autocompletePopover closePopover:nil];
            shouldComplete = NO;
            break;
        case 53:
            // Esc
            if (self.autocompletePopover.isVisible)
                [self.autocompletePopover closePopover:nil];
            return; // Skip default behavior
        case 125:
            // Down
            if (self.autocompletePopover.isVisible) {
                [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row+1] byExtendingSelection:NO];
                [self.autocompleteTableView scrollRowToVisible:self.autocompleteTableView.selectedRow];
                return; // Skip default behavior
            }
            break;
        case 126:
            // Up
            if (self.autocompletePopover.isVisible) {
                [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row-1] byExtendingSelection:NO];
                [self.autocompleteTableView scrollRowToVisible:self.autocompleteTableView.selectedRow];
                return; // Skip default behavior
            }
            break;
        case 36:
        case 48:
            // Return or tab
            if (self.autocompletePopover.isVisible) {
                [self insert:self];
                return; // Skip default behavior
            }
        case 49:
            // Space
            if (self.autocompletePopover.isVisible) {
                [self.autocompletePopover closePopover:nil];
            }
            break;
    }
    [super keyDown:theEvent];
    if (shouldComplete) {
        [self complete:self];
    }
}

- (void)insert:(id)sender {
    if (self.autocompleteTableView.selectedRow >= 0 && self.autocompleteTableView.selectedRow < self.matches.count) {
        NSString *word = [self.matches objectAtIndex:self.autocompleteTableView.selectedRow];
        NSInteger beginningOfWord = self.selectedRange.location - self.substring.length;
        NSDictionary *wordInfo = self.autocompleteInfo[word];
        if (wordInfo[@"extra"]) {
            word = [word stringByAppendingString:wordInfo[@"extra"]];
        }
        
        NSRange range = NSMakeRange(beginningOfWord, [self.substring length]);
        if ([self shouldChangeTextInRange:range replacementString:word]) {
            [self replaceCharactersInRange:range withString:word];
            [self didChangeText];
            
            if (wordInfo[@"select"]) {
                NSRange range = NSRangeFromString(wordInfo[@"select"]);
                range.location += beginningOfWord;
                [self setSelectedRange:range];
            }
        }
    }
    [self.autocompletePopover closePopover:nil];
}

- (void)didChangeSelection:(NSNotification *)notification {
    /*NSRange effectiveRange;
    if (self.selectedRange.location < [[self string] length]) {
        NSString *componentType = [[self textStorage] attribute:NCR_COMPONENT_NAME_ATTR atIndex:self.selectedRange.location effectiveRange:&effectiveRange];
        NSLog(@"%@: %@", componentType, NSStringFromRange(effectiveRange));
    }*/
    
    if (labs(self.selectedRange.location - self.lastPos) > 1) {
        // We check the textstorage delegate because it is set to NULL during syntax coloring (see colorRange:) in order to prevent an infinite loop when we replace the text. So if this method is called when the text is replaced, the delegate of textstorage will be null. We don't want to close the autocomplete popover whenever syntax coloring occurs.
        if ([[self textStorage] delegate] != NULL) {
            // If selection moves by more than just one character, hide autocomplete
            [self.autocompletePopover closePopover:nil];
        }
    }
}

- (void)complete:(id)sender {
    NSInteger firstWordBreak = -1;
    NSInteger secondWordBreak = -1;
    
    for (NSInteger i = self.selectedRange.location - 1; i >= 0; i--) {
        if ([self.keywordBoundaryChars characterIsMember:[self.string characterAtIndex:i]] || i == 0) {
            if (firstWordBreak == -1) {
                firstWordBreak = i == 0 ? 0 : i + 1;
            } else {
                secondWordBreak = i == 0 ? 0 : i + 1;
                break;
            }
        }
    }
    
    if (firstWordBreak == -1 && secondWordBreak == -1) {
        // Nothing typed
        [self.autocompletePopover closePopover:nil];
        return;
    }
    
    NSString *precedingWord = nil;
    if (secondWordBreak != -1) {
        precedingWord = [[self string] substringWithRange:NSMakeRange(secondWordBreak, firstWordBreak - secondWordBreak)];
    }
    
    //NSLog(@"word: %@ | preceding word: %@", [[self string] substringWithRange:NSMakeRange(firstWordBreak, self.selectedRange.location - firstWordBreak)], precedingWord);
    
    self.substring = [[self string] substringWithRange:NSMakeRange(firstWordBreak, self.selectedRange.location - firstWordBreak)];
    
    if ([self.substring length] == 0) {
        // Nothing has been typed yet
        [self.autocompletePopover closePopover:nil];
        return;
    }
    
    [self.matches removeAllObjects];
    for (NSString *word in self.autocompleteWords) {
        if ([word rangeOfString:self.substring options:NSAnchoredSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, [word length])].location != NSNotFound) {
            NSDictionary *wordInfo = self.autocompleteInfo[word];
            if (wordInfo[@"precededBy"]) {
                // If precededBy is a dot, match any preceding word that ends in a dot, otherwise match the entire word
                if (precedingWord && (([wordInfo[@"precededBy"] characterAtIndex:0] == '.' && [precedingWord hasSuffix:@"."]) || ([wordInfo[@"precededBy"] isEqualToString:precedingWord]))) {
                    [self.matches addObject:word];
                }
            } else {
                [self.matches addObject:word];
            }
        }
    }
    
    if ([self.matches count] > 0) {
        self.lastPos = self.selectedRange.location;
        [self.matches sortUsingSelector:@selector(compare:)];
        [self.autocompleteTableView reloadData];
        [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.autocompleteTableView scrollRowToVisible:0];
        
        // Make the frame for the popover. We want it to shrink with a small number
        // of items to autocomplete but never grow above a certain limit when there
        // are a lot of items. The limit is set by MAX_RESULTS.
        NSInteger numberOfRows = MIN(self.autocompleteTableView.numberOfRows, MAX_RESULTS);
        CGFloat height = (self.autocompleteTableView.rowHeight + self.autocompleteTableView.intercellSpacing.height) * numberOfRows + 2 * POPOVER_PADDING;
        NSRect frame = NSMakeRect(0, 0, POPOVER_WIDTH, height);
        [[[self.autocompletePopover popoverWindow] contentView] setFrame:NSInsetRect(frame, POPOVER_PADDING, POPOVER_PADDING)];
        [[self.autocompletePopover popoverWindow] setContentSize:NSMakeSize(NSWidth(frame), NSHeight(frame))];
        
        // We want to find the middle of the first character to show the popover.
        // firstRectForCharacterRange: will give us the rect at the beginning of
        // the word, and then we need to find the half-width of the first character
        // to add to it.
        NSRect rect = [self firstRectForCharacterRange:NSMakeRange(firstWordBreak, 0) actualRange:NULL];
        rect = [self.window convertRectFromScreen:rect];
        NSString *firstChar = [self.substring substringToIndex:1];
        NSSize firstCharSize = [firstChar sizeWithAttributes:@{NSFontAttributeName:self.font}];
        rect.size.width = firstCharSize.width;
        NSPoint attachmentPoint = NSMakePoint(NSMidX(rect), rect.origin.y);
        
        if (self.autocompletePopover.isVisible) {
            [self.autocompletePopover movePopoverToPoint:attachmentPoint];
        } else {
            [self.autocompletePopover displayPopoverInWindow:[self window] atPoint:attachmentPoint];
        }
    } else {
        [self.autocompletePopover closePopover:nil];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.matches.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTextField *result = [tableView makeViewWithIdentifier:@"MyView" owner:self];
    if (result == nil) {
        result = [[NSTextField alloc] initWithFrame:NSZeroRect];
        [result setBezeled:NO];
        [result setDrawsBackground:NO];
        [result setEditable:NO];
        [result setSelectable:NO];
        result.identifier = @"MyView";
    }
    
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:self.matches[row] attributes:@{NSFontAttributeName:POPOVER_FONT, NSForegroundColorAttributeName:POPOVER_TEXTCOLOR}];
    
    if (self.substring) {
        NSRange range = [as.string rangeOfString:self.substring options:NSAnchoredSearch|NSCaseInsensitiveSearch];
        [as addAttribute:NSFontAttributeName value:[[NSFontManager sharedFontManager] convertFont:POPOVER_FONT toHaveTrait:NSBoldFontMask] range:range];
    }
    
    [result setAttributedStringValue:as];
    
    return result;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[NCRAutocompleteTableRowView alloc] init];
}

#pragma mark - Syntax highlighting

- (void)setLanguage:(NSString *)language {
    NSString *path = [[NSBundle mainBundle] pathForResource:language ofType:@"plist"];
    self.syntax = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    
    for (NSInteger i = 0; i < [self.syntax[kComponentsKey] count]; i++) {
        NSMutableDictionary *compDict = [NSMutableDictionary dictionaryWithDictionary:self.syntax[kComponentsKey][i]];
        
        if ([compDict[kTypeKey] isEqualToString:kTypeKeywords]) {
            self.keywords = compDict[kStringArrayKey];
        }
        
        if (!compDict[kEndKey]) {
            self.syntax[kComponentsKey][i][kEndKey] = @"";
        }
        
        self.syntax[kComponentsKey][i][kFGColorKey] = [NSColor colorFromString:compDict[kFGColorKey] forColorSpace:[NSColorSpace deviceRGBColorSpace]];
        self.syntax[kComponentsKey][i][kBGColorKey] = [NSColor colorFromString:compDict[kBGColorKey] forColorSpace:[NSColorSpace deviceRGBColorSpace]];
    }
    
    NSArray *autocomplete = self.syntax[kAutocompleteKey];
    self.autocompleteWords = [autocomplete valueForKey:@"word"];
    self.autocompleteInfo = [NSDictionary dictionaryWithObjects:autocomplete forKeys:[autocomplete valueForKey:@"word"]];
}

- (void)textStorageDidProcessEditing:(NSNotification *)notification {
    NSTextStorage *textStorage = [notification object];
    NSString *string = [textStorage string];
    
    // Get the edited range
    NSRange range = [textStorage editedRange];
    
    if ([string length] == 0) {
        return;
    }
    
    // Scan up specified number of lines
    NSUInteger start = 0, end = [string length];
    for (NSInteger i = range.location; i > 0; i--) {
        if (i == 0) {
            break;
        }
        unichar c = [string characterAtIndex:i];
        if ([[NSCharacterSet newlineCharacterSet] characterIsMember:c]) {
            break;
        }
        start = i;
    }
    // Scan down specified number of lines
    for (NSInteger i = NSMaxRange(range); i < [string length]; i++) {
        NSLog(@"checking %li", i);
        unichar c = [string characterAtIndex:i];
        if ([[NSCharacterSet newlineCharacterSet] characterIsMember:c]) {
            break;
        }
        end = i;
    }
    
    range = NSMakeRange(start, end-start);
    
    NSLog(@"%@", NSStringFromRange(range));
    
    return;
    NSLog(@"%@", [string substringWithRange:range]);
    
    // Re-color on next iteration of run loop so that NSTextStorage doesn't get messed up
    [self performBlock:^{
        NSRange selectedRange = [self selectedRange];
        [self colorRange:range];
        [self setSelectedRange:selectedRange];
    } afterDelay:0.0];
}

- (void)colorRange:(NSRange)range {
    NSString *string = [self string];
    if (NSMaxRange(range) > [string length]) {
        return;
    }
    NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] initWithString:[string substringWithRange:range] attributes:self.defaultTextAttributes];
    
    BOOL keywordBoundaryPassed = YES;
    
    for (NSInteger i = range.location; i < NSMaxRange(range); i++) {
        // For each character in the range, iterate over all components to check for a match
        for (NSDictionary *component in self.syntax[kComponentsKey]) {
            if ([self matchString:component[kStartKey] inString:string atIndex:i escape:component[kEscapeKey]]) {
                // Matched the start string of a component, now look for end
                NSInteger start = i;
                NSInteger end = 0;
                
                // Check boundary -- certain components need to be preceeded by certain chars or strings. This can be specified by the 'boundary' key in the syntax dictionary.
                if (component[kBoundaryKey]) {
                    if (i-1 >= 0 && [[NSCharacterSet newlineCharacterSet] characterIsMember:[string characterAtIndex:i-1]]) {
                        // Starts on a newline, this counts as a boundary
                    } else {
                        NSInteger last = 0, first = 0;
                        for (NSInteger j = i-1; j >= 0; j--) {
                            if ([[NSCharacterSet whitespaceCharacterSet] characterIsMember:[string characterAtIndex:j]]) {
                                continue;
                            }
                            last = j;
                            break;
                        }
                        for (NSInteger j = last; j >= 0; j--) {
                            if (![[NSCharacterSet whitespaceCharacterSet] characterIsMember:[string characterAtIndex:j]]) {
                                continue;
                            }
                            first = j+1;
                            break;
                        }
                        NSString *prevWord = [string substringWithRange:NSMakeRange(first, last-first+1)];
                        NSString *lastCharOfPrevWord = [prevWord substringFromIndex:[prevWord length]-1];
                        if (![component[kBoundaryKey] containsObject:prevWord] && ![component[kBoundaryKey] containsObject:lastCharOfPrevWord]) {
                            continue;
                        }
                    }
                }
                
                // Add the length of the start string so we start looking after it
                i += [component[kStartKey] length];
                
                BOOL shouldColor = NO;
                if ([component[kEndKey] length] == 0 && i == [string length]) {
                    // This is to match components that don't have an end string but terminate on a newline or end of string
                    shouldColor = YES;
                    end = NSMaxRange(range);
                } else {
                    // Look for end string
                    for (NSUInteger j = i; j < [string length]; j++) {
                        if ([self matchString:component[kEndKey] inString:string atIndex:j escape:component[kEscapeKey]]) {
                            i += (j - i + [component[kEndKey] length]); // add the difference between the end and start
                            i -= 1; // Because 1 is added on next iteration of loop
                            shouldColor = YES;
                            end = j;
                            break;
                        } else if (![component[kTypeKey] isEqualToString:kTypeBlockComment] && [self matchString:@"" inString:string atIndex:j escape:nil]) {
                            // Unless the component is a block comment, stop at end of line
                            end = j;
                            break;
                        } else if ([component[kEndKey] length] == 0 && j == [string length]-1) {
                            // The end string was blank so we should match on a newline, but we reached the end of the string so that counts too
                            shouldColor = YES;
                            end = [string length];
                        }
                    }
                }
                
                if (shouldColor) {
                    NSRange rangeInString = NSMakeRange(start-range.location, end-start+[component[kEndKey] length]);
                    if (NSMaxRange(rangeInString) > [attrString length]) {
                        rangeInString.length--;
                    }
                    if (NSMaxRange(rangeInString) <= [attrString length]) {
                        [attrString setAttributes:@{NSFontAttributeName:DEFAULT_FONT, NSForegroundColorAttributeName:component[kFGColorKey], NSBackgroundColorAttributeName:component[kBGColorKey]} range:rangeInString];
                    }
                    
                }
            }
            
            
            // Don't bother checking for keywords unless a boundary char was already passed
            if (i < [string length] && [self.keywordBoundaryChars characterIsMember:[string characterAtIndex:i]]) {
                keywordBoundaryPassed = YES;
            } else if (keywordBoundaryPassed) {
                keywordBoundaryPassed = NO;
                for (NSString *keyword in self.keywords) {
                    if ([self matchString:keyword inString:string atIndex:i escape:nil]) {
                        // A keyword has to end in a boundary char too, or be at the end of the string
                        if ((i+[keyword length] < [string length] && [self.keywordBoundaryChars characterIsMember:[string characterAtIndex:i+[keyword length]]]) || (i+[keyword length] == [string length])) {
                            
                            NSRange rangeInString = NSMakeRange(i-range.location, [keyword length]);
                            
                            if (NSMaxRange(rangeInString) > [attrString length]) {
                                rangeInString.length--;
                            }
                            if (NSMaxRange(rangeInString) <= [attrString length]) {
                                NSFont *font = [[NSFontManager sharedFontManager] convertFont:DEFAULT_FONT toHaveTrait:NSBoldFontMask];
                                i += [keyword length];
                                [attrString setAttributes:@{NSFontAttributeName:font} range:rangeInString];
                            }
                            break;
                        }
                    }
                }
            }
            
        }
    }
    
    // Replace the range with our recolored part -- we temporarily set the textstorage delegate to nil so it doesn't call textStorageDidProcessEditing:, creating an infinite loop
    [[self textStorage] setDelegate:nil];
    [[self textStorage] replaceCharactersInRange:range withAttributedString:attrString];
    [[self textStorage] fixFontAttributeInRange:range];
    [[self textStorage] setDelegate:self];
}

- (BOOL)matchString:(NSString *)s inString:(NSString *)string atIndex:(NSUInteger)i escape:(NSString *)escape {
    if (!s) {
        return NO;
    }
    if (i >= [string length]) {
        return NO;
    }
    
    unichar c = [string characterAtIndex:i];
    
    // If char is empty, match to end of line
    if ([s length] == 0) {
        return [[NSCharacterSet newlineCharacterSet] characterIsMember:c];
    }
    
    if (c == [s characterAtIndex:0]) {
        // First characters match, continue trying to match
        if (escape && i > 0 && [self isEscapedAtIndex:i escapeChar:[escape characterAtIndex:0] string:string]) {
            return NO;
        }
        BOOL isMatch = YES;
        NSInteger j;
        for (j = 0; j < [s length]; j++) {
            if (i+j < [string length]) {
                if ([string characterAtIndex:i+j] != [s characterAtIndex:j]) {
                    isMatch = NO;
                    break;
                }
            } else {
                isMatch = NO;
                break;
            }
        }
        return isMatch;
    }
    return NO;
}

- (BOOL)isEscapedAtIndex:(NSUInteger)i escapeChar:(unichar)escape string:(NSString *)s {
    // If an odd number of escape char precedes the char, we are escaping, otherwise we're not
    NSInteger count = 0;
    i--;
    while ([s characterAtIndex:i] == '\\') {
        count++;
        i--;
    }
    if (count % 2) {
        // Odd
        return YES;
    }
    return NO;
}

@end
