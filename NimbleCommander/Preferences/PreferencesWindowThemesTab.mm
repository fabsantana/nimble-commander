//
//  PreferencesWindowThemesTab.m
//  NimbleCommander
//
//  Created by Michael G. Kazakov on 1/17/17.
//  Copyright © 2017 Michael G. Kazakov. All rights reserved.
//

#include <fstream>
#include <rapidjson/error/en.h>
#include <rapidjson/memorystream.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/prettywriter.h>
#include <NimbleCommander/Bootstrap/Config.h>
#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include <NimbleCommander/Core/Theming/ThemesManager.h>
#include <NimbleCommander/Core/Theming/ThemePersistence.h>
#include <NimbleCommander/States/FilePanels/PanelViewPresentationItemsColoringFilter.h>
#include "PreferencesWindowThemesTab.h"
#include "PreferencesWindowThemesControls.h"
#include "PreferencesWindowThemesTabModel.h"

static NSTextField *SpawnSectionTitle( NSString *_title )
{
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 0, 0)];
    tf.stringValue = _title;
    tf.bordered = false;
    tf.editable = false;
    tf.drawsBackground = false;
    tf.font = [NSFont labelFontOfSize:13];
    return tf;
}

static NSTextField *SpawnEntryTitle( NSString *_title )
{
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 0, 0)];
    tf.stringValue = _title;
    tf.bordered = false;
    tf.editable = false;
    tf.drawsBackground = false;
    tf.font = [NSFont labelFontOfSize:11];
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    return tf;
}

@interface PreferencesWindowThemesTab ()
@property (strong) IBOutlet NSOutlineView *outlineView;
@property (strong) IBOutlet NSPopUpButton *themesPopUp;
@property bool selectedThemeCanBeRemoved;
@property bool selectedThemeCanBeReverted;
@end

@implementation PreferencesWindowThemesTab
{
    NSArray *m_Nodes;
    rapidjson::StandaloneDocument m_Doc;
    ThemesManager *m_Manager;
    vector<string> m_ThemeNames;
    int m_SelectedTheme;
    
}


- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:NSStringFromClass(self.class) bundle:nibBundleOrNil];
    if (self) {
        m_Manager = &AppDelegate.me.themesManager;
        [self loadThemesNames];
        [self loadSelectedDocument];
        
        m_Nodes = BuildThemeSettingsNodesTree();
    }
    
    return self;
}

- (void) loadThemesNames
{
    m_ThemeNames = m_Manager->ThemeNames();
    assert( !m_ThemeNames.empty() ); // there should be at least 3 default themes!
    m_SelectedTheme = 0;
    auto it = find(begin(m_ThemeNames), end(m_ThemeNames), m_Manager->SelectedThemeName());
    if( it != end(m_ThemeNames) )
        m_SelectedTheme = (int)distance( begin(m_ThemeNames), it );
}

- (void) buildThemeNamesPopup
{
    [self.themesPopUp removeAllItems];
    for( int i = 0, e = (int)m_ThemeNames.size(); i != e; ++i ) {
        auto &name = m_ThemeNames[i];
        [self.themesPopUp addItemWithTitle:[NSString stringWithUTF8StdString:name]];
        self.themesPopUp.lastItem.tag = i;
    }
    [self.themesPopUp selectItemWithTag:m_SelectedTheme];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do view setup here.
        
    [self buildThemeNamesPopup];
    [self.outlineView expandItem:nil expandChildren:true];
}

-(NSString*)identifier
{
    return NSStringFromClass(self.class);
}

-(NSImage*)toolbarItemImage
{
    return [[NSImage alloc] initWithContentsOfFile:
     @"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ProfileFontAndColor.icns"];
}

-(NSString*)toolbarItemLabel
{
    return NSLocalizedStringFromTable(@"Themes",
                                      @"Preferences",
                                      "General preferences tab title");
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item
{
    if( item == nil )
        return m_Nodes.count;
    if( auto n = objc_cast<PreferencesWindowThemesTabGroupNode>(item) )
        return n.children.count;
    return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item
{
    if( item == nil )
        return m_Nodes[index];
    if( auto n = objc_cast<PreferencesWindowThemesTabGroupNode>(item) )
        return n.children[index];
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    return objc_cast<PreferencesWindowThemesTabGroupNode>(item) != nil;
}

- (nullable NSView *)outlineView:(NSOutlineView *)outlineView
              viewForTableColumn:(nullable NSTableColumn *)tableColumn
                            item:(id)item
{
    if( auto n = objc_cast<PreferencesWindowThemesTabGroupNode>(item) ) {
        if( [tableColumn.identifier isEqualToString:@"title"] )
            return SpawnSectionTitle(n.title);
        
    
        return nil;
    }
    if( auto i = objc_cast<PreferencesWindowThemesTabItemNode>(item) ) {
        if( [tableColumn.identifier isEqualToString:@"title"] )
            return SpawnEntryTitle(i.title);
    
        if( [tableColumn.identifier isEqualToString:@"value"] ) {
            if( i.type == PreferencesWindowThemesTabItemType::Color ) {
                auto v = [[PreferencesWindowThemesTabColorControl alloc] initWithFrame:NSRect{}];
                v.color = ThemePersistence::ExtractColor(self.selectedThemeFrontend,
                                                         i.entry.c_str());
                v.action = @selector(onColorChanged:);
                v.target = self;
                return v;
            }
            if( i.type == PreferencesWindowThemesTabItemType::Font ) {
                auto v = [[PreferencesWindowThemesTabFontControl alloc] initWithFrame:NSRect{}];
                v.font = ThemePersistence::ExtractFont(self.selectedThemeFrontend,
                                                       i.entry.c_str());
                v.action = @selector(onFontChanged:);
                v.target = self;
                return v;
            }
            if( i.type == PreferencesWindowThemesTabItemType::ColoringRules ) {
                auto v = [[PreferencesWindowThemesTabColoringRulesControl alloc]
                          initWithFrame:NSRect{}];
                v.rules = ThemePersistence::ExtractRules(self.selectedThemeFrontend,
                                                       i.entry.c_str());
                v.action = @selector(onColoringRulesChanged:);
                v.target = self;
                return v;
            }
            if( i.type == PreferencesWindowThemesTabItemType::Appearance ) {
                auto v = [[PreferencesWindowThemesAppearanceControl alloc] initWithFrame:NSRect{}];
                v.themeAppearance = ThemePersistence::ExtractAppearance(self.selectedThemeFrontend,
                                                                        i.entry.c_str());
                v.action = @selector(onAppearanceChanged:);
                v.target = self;
                return v;
            }
        }
    }
    
    return nil;
}

- (void)onAppearanceChanged:(id)sender
{
    if( const auto v = objc_cast<PreferencesWindowThemesAppearanceControl>(sender) ) {
        const auto row = [self.outlineView rowForView:v];
        const id item = [self.outlineView itemAtRow:row];
        if( const auto node = objc_cast<PreferencesWindowThemesTabItemNode>(item) )
            [self commitChangedValue:ThemePersistence::EncodeAppearance(v.themeAppearance)
                              forKey:node.entry];
    }
}

- (void)onColoringRulesChanged:(id)sender
{
    if( const auto v = objc_cast<PreferencesWindowThemesTabColoringRulesControl>(sender) ) {
        const auto row = [self.outlineView rowForView:v];
        const id item = [self.outlineView itemAtRow:row];
        if( const auto node = objc_cast<PreferencesWindowThemesTabItemNode>(item) )
            [self commitChangedValue:ThemePersistence::EncodeRules(v.rules)
                              forKey:node.entry];
    }
}

- (void)onColorChanged:(id)sender
{
    if( const auto v = objc_cast<PreferencesWindowThemesTabColorControl>(sender) ) {
        const auto row = [self.outlineView rowForView:v];
        const id item = [self.outlineView itemAtRow:row];
        if( const auto node = objc_cast<PreferencesWindowThemesTabItemNode>(item) )
            [self commitChangedValue:ThemePersistence::EncodeColor(v.color)
                              forKey:node.entry];
    }
}

- (void)onFontChanged:(id)sender
{
    if( const auto v = objc_cast<PreferencesWindowThemesTabFontControl>(sender) ) {
        const auto row = [self.outlineView rowForView:v];
        const id item = [self.outlineView itemAtRow:row];
        if( const auto node = objc_cast<PreferencesWindowThemesTabItemNode>(item) )
            [self commitChangedValue:ThemePersistence::EncodeFont(v.font)
                              forKey:node.entry];
    }
}

- (const rapidjson::StandaloneDocument &) selectedThemeFrontend
{
    return m_Doc; // possibly some more logic here
}
/* also theme backend if any */

- (void) commitChangedValue:(const rapidjson::StandaloneValue&)_value forKey:(const string&)_key
{
    // CHECKS!!!
    const auto &theme_name = m_ThemeNames[m_SelectedTheme];
    m_Manager->SetThemeValue( theme_name, _key, _value );
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item
{
    if( auto i = objc_cast<PreferencesWindowThemesTabItemNode>(item) )
        if( i.type == PreferencesWindowThemesTabItemType::ColoringRules )
            return 140;

    return 18;
}

- (IBAction)onThemesPopupChange:(id)sender
{
    int selected_ind = (int)self.themesPopUp.selectedTag;
    if( selected_ind >= 0 && selected_ind < m_ThemeNames.size() )
        if( m_Manager->SelectTheme(m_ThemeNames[selected_ind]) ) {
            m_SelectedTheme = selected_ind;
            [self loadSelectedDocument];
            [self.outlineView reloadData];
        }
}

- (void) loadSelectedDocument
{
    // CHECKS!!!
    const auto &theme_name = m_ThemeNames.at(m_SelectedTheme);
    m_Doc.CopyFrom( *m_Manager->ThemeData(theme_name), rapidjson::g_CrtAllocator );
    
    
    self.selectedThemeCanBeRemoved = m_Manager->CanBeRemoved(theme_name);
    self.selectedThemeCanBeReverted = m_Manager->HasDefaultSettings(theme_name);
}

- (IBAction)onRevertClicked:(id)sender
{
    if( m_Manager->DiscardThemeChanges(m_ThemeNames[m_SelectedTheme]) ) {
        [self loadSelectedDocument];
        [self.outlineView reloadData];
    }
}

- (IBAction)onExportClicked:(id)sender
{
    auto name = m_ThemeNames[m_SelectedTheme];
    if( auto v = m_Manager->ThemeData(name) ) {
        rapidjson::StringBuffer buffer;
        rapidjson::PrettyWriter<rapidjson::StringBuffer> writer(buffer);
        v->Accept(writer);
        
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.nameFieldStringValue = [NSString stringWithUTF8StdString:name];
        panel.allowedFileTypes = @[@"json"];
        panel.allowsOtherFileTypes = false;
        panel.directoryURL = [NSFileManager.defaultManager URLForDirectory:NSDesktopDirectory
                                                                  inDomain:NSUserDomainMask
                                                         appropriateForURL:nil
                                                                    create:false
                                                                     error:nil];
        if( [panel runModal] == NSFileHandlingPanelOKButton )
            if( panel.URL != nil ) {
                auto data = [NSData dataWithBytes:buffer.GetString()
                                           length:buffer.GetSize()];
                [data writeToURL:panel.URL atomically:true];
            }
    }
}

- (IBAction)onImportClicked:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"json"];
    panel.allowsOtherFileTypes = false;
    if( [panel runModal] == NSFileHandlingPanelOKButton )
        if( panel.URL != nil )
            if( auto d = [NSData dataWithContentsOfURL:panel.URL] ) {
                string str { (const char*)d.bytes, d.length };
            
                rapidjson::Document doc;
                rapidjson::ParseResult ok = doc.Parse<rapidjson::kParseCommentsFlag>( str.c_str() );
                if( ok ) {
                    auto name = m_ThemeNames[m_SelectedTheme];
                    rapidjson::StandaloneDocument sdoc;
                    sdoc.CopyFrom(doc, rapidjson::g_CrtAllocator);
                    if( m_Manager->ImportThemeData( name, sdoc ) ) {
                        [self loadSelectedDocument];
                        [self.outlineView reloadData];
                    }                    
                }
            }
}

- (IBAction)onDuplicateClicked:(id)sender
{
    const auto theme_name = m_ThemeNames.at(m_SelectedTheme);
    if( m_Manager->AddTheme(m_Manager->SuitableNameForNewTheme(theme_name),
                            self.selectedThemeFrontend) ) {
        [self reloadAll];
    }
}

- (void) reloadAll
{
    [self loadThemesNames];
    [self loadSelectedDocument];
    [self buildThemeNamesPopup];
    [self.outlineView reloadData];
}

- (IBAction)onRemoveClicked:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Are you sure you want to remove this theme?",
        "Asking user for confirmation on erasing custom theme - message");
    alert.informativeText = NSLocalizedString(@"You can’t undo this action.",
        "Asking user for confirmation on erasing custom theme - informative text");
    [alert addButtonWithTitle:NSLocalizedString(@"Yes", "")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "")];
    if( [alert runModal] == NSAlertFirstButtonReturn ) {
        const auto theme_name = m_ThemeNames.at(m_SelectedTheme);
        if( m_Manager->RemoveTheme(theme_name) )
            [self reloadAll];
    }
}

@end
