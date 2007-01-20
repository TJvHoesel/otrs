# --
# Kernel/Modules/AgentTicketPrint.pm - to get a closer view
# Copyright (C) 2001-2007 OTRS GmbH, http://otrs.org/
# --
# $Id: AgentTicketPrint.pm,v 1.33 2007-01-20 18:04:49 mh Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Kernel::Modules::AgentTicketPrint;

use strict;
use Kernel::System::CustomerUser;
use Kernel::System::LinkObject;
use Kernel::System::PDF;

use vars qw($VERSION);
$VERSION = '$Revision: 1.33 $';
$VERSION =~ s/^\$.*:\W(.*)\W.+?$/$1/;

sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object
    my $Self = {};
    bless ($Self, $Type);

    foreach (keys %Param) {
        $Self->{$_} = $Param{$_};
    }

    # check needed Opjects
    foreach (qw(ParamObject DBObject TicketObject LayoutObject LogObject QueueObject ConfigObject UserObject MainObject)) {
        if (!$Self->{$_}) {
            $Self->{LayoutObject}->FatalError(Message => "Got no $_!");
        }
    }

    # customer user object
    $Self->{CustomerUserObject} = Kernel::System::CustomerUser->new(%Param);
    # link object
    $Self->{LinkObject} = Kernel::System::LinkObject->new(%Param);
    $Self->{PDFObject} = Kernel::System::PDF->new(%Param);

    return $Self;
}

sub Run {
    my $Self = shift;
    my %Param = @_;
    my $Output;
    my $QueueID = $Self->{TicketObject}->TicketQueueID(TicketID => $Self->{TicketID});
    # check needed stuff
    if (!$Self->{TicketID} || !$QueueID) {
        return $Self->{LayoutObject}->Error(Message => 'Need TicketID!');
    }
    # check permissions
    if (!$Self->{TicketObject}->Permission(
        Type => 'ro',
        TicketID => $Self->{TicketID},
        UserID => $Self->{UserID})) {
        # error screen, don't show ticket
        return $Self->{LayoutObject}->NoPermission(WithHeader => 'yes');
    }
    # get linked objects
    my %Links = $Self->{LinkObject}->AllLinkedObjects(
        Object => 'Ticket',
        ObjectID => $Self->{TicketID},
        UserID => $Self->{UserID},
    );
    # get content
    my %Ticket = $Self->{TicketObject}->TicketGet(TicketID => $Self->{TicketID});
    my @ArticleBox = $Self->{TicketObject}->ArticleContentIndex(TicketID => $Self->{TicketID});
    $Ticket{TicketTimeUnits} = $Self->{TicketObject}->TicketAccountedTimeGet(TicketID => $Ticket{TicketID});
    # article attachments
    foreach my $Article (@ArticleBox) {
        my %AtmIndex = $Self->{TicketObject}->ArticleAttachmentIndex(
            ContentPath => $Article->{ContentPath},
            ArticleID => $Article->{ArticleID},
        );
        $Article->{Atms} = \%AtmIndex;
    }
    # user info
    my %UserInfo = $Self->{UserObject}->GetUserData(
        User => $Ticket{Owner},
        Cached => 1
    );
    # customer info
    my %CustomerData = ();
    if ($Ticket{CustomerUserID}) {
        %CustomerData = $Self->{CustomerUserObject}->CustomerUserDataGet(
            User => $Ticket{CustomerUserID},
        );
    }
    elsif ($Ticket{CustomerID}) {
        %CustomerData = $Self->{CustomerUserObject}->CustomerUserDataGet(
            CustomerID => $Ticket{CustomerID},
        );
    }
    # do some html quoting
    $Ticket{Age} = $Self->{LayoutObject}->CustomerAge(Age => $Ticket{Age}, Space => ' ');
    if ($Ticket{UntilTime}) {
        $Ticket{PendingUntil} = $Self->{LayoutObject}->CustomerAge(
            Age => $Ticket{UntilTime},
            Space => ' ',
        );
    }
    else {
        $Ticket{PendingUntil} = '-';
    }
    # prepare escalation time (if needed)
    if ($Ticket{TicketOverTime}) {
        $Ticket{TicketOverTime} = $Self->{LayoutObject}->CustomerAge(
            Age => $Ticket{TicketOverTime},
            Space => ' ',
        );
    }
    else {
        $Ticket{TicketOverTime} = '-';
    }

    # generate pdf output
    if ($Self->{PDFObject}) {
        my $PrintedBy = $Self->{LayoutObject}->{LanguageObject}->Get('printed by');
        my $Time = $Self->{LayoutObject}->Output(Template => '$Env{"Time"}');
        my $Url = ' ';
        if ($ENV{REQUEST_URI}) {
            $Url = $Self->{ConfigObject}->Get('HttpType') . '://' .
                $Self->{ConfigObject}->Get('FQDN') .
                $ENV{REQUEST_URI};
        }
        my %Page;
        # get maximum number of pages
        $Page{MaxPages} = $Self->{ConfigObject}->Get('PDF::MaxPages');
        if (!$Page{MaxPages} || $Page{MaxPages} < 1 || $Page{MaxPages} > 1000) {
            $Page{MaxPages} = 100;
        }
        my $HeaderRight = $Self->{ConfigObject}->Get('Ticket::Hook') . $Ticket{TicketNumber};
        my $HeadlineLeft = $HeaderRight;
        my $Title = $HeaderRight;
        if ($Ticket{Title}) {
            $HeadlineLeft = $Ticket{Title};
            $Title .= ' / ' . $Ticket{Title};
        }

        $Page{MarginTop} = 30;
        $Page{MarginRight} = 40;
        $Page{MarginBottom} = 40;
        $Page{MarginLeft} = 40;
        $Page{HeaderRight} = $HeaderRight;
        $Page{HeadlineLeft} = $HeadlineLeft;
        $Page{HeadlineRight} = $PrintedBy . ' ' .
            $Self->{UserFirstname} . ' ' .
            $Self->{UserLastname} . ' (' .
            $Self->{UserEmail} . ') ' .
            $Time;
        $Page{FooterLeft} = $Url;
        $Page{PageText} = $Self->{LayoutObject}->{LanguageObject}->Get('Page');
        $Page{PageCount} = 1;

        # create new pdf document
        $Self->{PDFObject}->DocumentNew(
            Title => $Self->{ConfigObject}->Get('Product') . ': ' . $Title,
        );
        # create first pdf page
        $Self->{PDFObject}->PageNew(
            %Page,
            FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
        );
        $Page{PageCount}++;
        # output ticket infos
        $Self->_PDFOutputTicketInfos(
            PageData => \%Page,
            TicketData => \%Ticket,
            UserData => \%UserInfo,
        );
        # output ticket freetext fields
        $Self->_PDFOutputTicketFreeText(
            PageData => \%Page,
            TicketData => \%Ticket,
        );
        # output ticket freetime fields
        $Self->_PDFOutputTicketFreeTime(
            PageData => \%Page,
            TicketData => \%Ticket,
        );
        # output linked objects
        $Self->_PDFOutputLinkedObjects(
            PageData => \%Page,
            LinkData => \%Links,
        );
        # output customer infos
        if (%CustomerData) {
            $Self->_PDFOutputCustomerInfos(
                PageData => \%Page,
                CustomerData => \%CustomerData,
            );
        }
        # output articles
        $Self->_PDFOutputArticles(
            PageData => \%Page,
            ArticleData => \@ArticleBox,
        );

        # return the pdf document
        my $Filename = 'ticket_' . $Ticket{TicketNumber};
        my ($s,$m,$h, $D,$M,$Y) = $Self->{TimeObject}->SystemTime2Date(
            SystemTime => $Self->{TimeObject}->SystemTime(),
        );
        $M = sprintf("%02d", $M);
        $D = sprintf("%02d", $D);
        $h = sprintf("%02d", $h);
        $m = sprintf("%02d", $m);
        my $PDFString = $Self->{PDFObject}->DocumentOutput();
        return $Self->{LayoutObject}->Attachment(
            Filename => $Filename."_"."$Y-$M-$D"."_"."$h-$m.pdf",
            ContentType => "application/pdf",
            Content => $PDFString,
            Type => 'attachment',
        );
    }
    # generate html output
    else {
        # output header
        $Output .= $Self->{LayoutObject}->PrintHeader(Value => $Ticket{TicketNumber});
        # output linked objects
        foreach my $LinkType (sort keys %Links) {
            my %ObjectType = %{$Links{$LinkType}};
            foreach my $Object (sort keys %ObjectType) {
                my %Data = %{$ObjectType{$Object}};
                foreach my $Item (sort keys %Data) {
                    $Self->{LayoutObject}->Block(
                        Name => "Link$LinkType",
                        Data => $Data{$Item},
                    );
                }
            }
        }
        # output customer infos
        if (%CustomerData) {
            $Param{CustomerTable} = $Self->{LayoutObject}->AgentCustomerViewTable(
                Data => \%CustomerData,
                Max => 100,
            );
        }
        # show ticket
        $Output .= $Self->_HTMLMask(
            TicketID => $Self->{TicketID},
            QueueID => $QueueID,
            ArticleBox => \@ArticleBox,
            %Param,
            %UserInfo,
            %Ticket,
        );
        # add footer
        $Output .= $Self->{LayoutObject}->PrintFooter();

        # return output
        return $Output;
    }
}

sub _PDFOutputTicketInfos {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(PageData TicketData UserData)) {
        if (!defined ($Param{$_})) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my %Ticket = %{$Param{TicketData}};
    my %UserInfo = %{$Param{UserData}};
    my %Page = %{$Param{PageData}};
    my %TableParam;
    $TableParam{CellData}[0][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('State') . ':';
    $TableParam{CellData}[0][0]{Font} = 'HelveticaBold';
    $TableParam{CellData}[0][1]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get($Ticket{State});
    $TableParam{CellData}[0][2]{Content} = ' ';
    $TableParam{CellData}[0][2]{BackgroundColor} = '#FFFFFF';
    $TableParam{CellData}[0][3]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Age') . ':';
    $TableParam{CellData}[0][3]{Font} = 'HelveticaBold';
    $TableParam{CellData}[0][4]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get($Ticket{Age});

    $TableParam{CellData}[1][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Priority') . ':';
    $TableParam{CellData}[1][0]{Font} = 'HelveticaBold';
    $TableParam{CellData}[1][1]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get($Ticket{Priority});
    $TableParam{CellData}[1][2]{Content} = ' ';
    $TableParam{CellData}[1][2]{BackgroundColor} = '#FFFFFF';
    $TableParam{CellData}[1][3]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Created') . ':';
    $TableParam{CellData}[1][3]{Font} = 'HelveticaBold';
    $TableParam{CellData}[1][4]{Content} =
        $Self->{LayoutObject}->Output(
            Template => '$TimeLong{"$Data{"Created"}"}',
            Data => \%Ticket,
        );
    $TableParam{CellData}[2][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Queue') . ':';
    $TableParam{CellData}[2][0]{Font} = 'HelveticaBold';
    $TableParam{CellData}[2][1]{Content} = $Ticket{Queue};
    $TableParam{CellData}[2][2]{Content} = ' ';
    $TableParam{CellData}[2][2]{BackgroundColor} = '#FFFFFF';
    $TableParam{CellData}[2][3]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Accounted time') . ':';
    $TableParam{CellData}[2][3]{Font} = 'HelveticaBold';
    $TableParam{CellData}[2][4]{Content} = $Ticket{TicketTimeUnits};

    $TableParam{CellData}[3][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Lock') . ':';
    $TableParam{CellData}[3][0]{Font} = 'HelveticaBold';
    $TableParam{CellData}[3][1]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get($Ticket{Lock});
    $TableParam{CellData}[3][2]{Content} = ' ';
    $TableParam{CellData}[3][2]{BackgroundColor} = '#FFFFFF';
    $TableParam{CellData}[3][3]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Escalation in') . ':';
    $TableParam{CellData}[3][3]{Font} = 'HelveticaBold';
    $TableParam{CellData}[3][4]{Content} = $Ticket{TicketOverTime};

    $TableParam{CellData}[4][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('CustomerID') . ':';
    $TableParam{CellData}[4][0]{Font} = 'HelveticaBold';
    $TableParam{CellData}[4][1]{Content} = $Ticket{CustomerID};
    $TableParam{CellData}[4][2]{Content} = ' ';
    $TableParam{CellData}[4][2]{BackgroundColor} = '#FFFFFF';
    $TableParam{CellData}[4][3]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Pending till') . ':';
    $TableParam{CellData}[4][3]{Font} = 'HelveticaBold';
    $TableParam{CellData}[4][4]{Content} = $Ticket{PendingUntil};

    $TableParam{CellData}[5][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Owner') . ':';
    $TableParam{CellData}[5][0]{Font} = 'HelveticaBold';
    $TableParam{CellData}[5][1]{Content} = $Ticket{Owner} . ' (' . $UserInfo{UserFirstname} . ' ' . $UserInfo{UserLastname} . ')';
    $TableParam{CellData}[5][2]{Content} = ' ';
    $TableParam{CellData}[5][2]{BackgroundColor} = '#FFFFFF';
    $TableParam{CellData}[5][3]{Content} = ' ';
    $TableParam{CellData}[5][3]{Font} = 'HelveticaBold';
    $TableParam{CellData}[5][4]{Content} = ' ';

    $TableParam{ColumnData}[0]{Width} = 80;
    $TableParam{ColumnData}[1]{Width} = 170.5;
    $TableParam{ColumnData}[2]{Width} = 4;
    $TableParam{ColumnData}[3]{Width} = 80;
    $TableParam{ColumnData}[4]{Width} = 170.5;

    $TableParam{Type} = 'Cut';
    $TableParam{Border} = 0;
    $TableParam{FontSize} = 6;
    $TableParam{BackgroundColorEven} = '#AAAAAA';
    $TableParam{BackgroundColorOdd} = '#DDDDDD';
    $TableParam{Padding} = 1;
    $TableParam{PaddingTop} = 3;
    $TableParam{PaddingBottom} = 3;

    # output table
    for ($Page{PageCount}..$Page{MaxPages}) {
        # output table (or a fragment of it)
        %TableParam = $Self->{PDFObject}->Table(
            %TableParam,
        );
        # stop output or output next page
        if ($TableParam{State}) {
            last;
        }
        else {
            $Self->{PDFObject}->PageNew(
                %Page,
                FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
            );
            $Page{PageCount}++;
        }
    }
}

sub _PDFOutputLinkedObjects {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(PageData LinkData)) {
        if (!defined ($Param{$_})) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my %Links = %{$Param{LinkData}};
    my %Page = %{$Param{PageData}};
    my $LONormal;
    my $LOParent;
    my $LOChild;
    # generate strings
    foreach my $LinkType (sort keys %Links) {
        my %ObjectType = %{$Links{$LinkType}};
        foreach my $Object (sort keys %ObjectType) {
            my %Data = %{$ObjectType{$Object}};
            foreach my $Item (sort keys %Data) {
                if ($LinkType eq 'Normal') {
                    $LONormal .= $Data{$Item}{Text} . ' ';
                }
                elsif ($LinkType eq 'Parent') {
                    $LOParent .= $Data{$Item}{Text} . ' ';
                }
                elsif  ($LinkType eq 'Child') {
                    $LOChild .= $Data{$Item}{Text} . ' ';
                }
            }
        }
    }
    # output linked objects
    if ($LONormal || $LOParent || $LOChild) {
        my %TableParam;
        my $Row = 0;
        if ($LONormal) {
            $TableParam{CellData}[$Row][0]{Content} =
                $Self->{LayoutObject}->{LanguageObject}->Get('Normal') . ':';
            $TableParam{CellData}[$Row][0]{Font} = 'HelveticaBold';
            $TableParam{CellData}[$Row][1]{Content} = $LONormal;
            $Row++;
        }
        if ($LOParent) {
            $TableParam{CellData}[$Row][0]{Content} =
                $Self->{LayoutObject}->{LanguageObject}->Get('Parent') . ':';
            $TableParam{CellData}[$Row][0]{Font} = 'HelveticaBold';
            $TableParam{CellData}[$Row][1]{Content} = $LOParent;
            $Row++;
        }
        if ($LOChild) {
            $TableParam{CellData}[$Row][0]{Content} =
                $Self->{LayoutObject}->{LanguageObject}->Get('Child') . ':';
            $TableParam{CellData}[$Row][0]{Font} = 'HelveticaBold';
            $TableParam{CellData}[$Row][1]{Content} = $LOChild;
            $Row++;
        }
        $TableParam{ColumnData}[0]{Width} = 80;
        $TableParam{ColumnData}[1]{Width} = 431;

        # set new position
        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -15,
        );
        # output headline
        $Self->{PDFObject}->Text(
            Text => $Self->{LayoutObject}->{LanguageObject}->Get('Linked Objects'),
            Height => 7,
            Type => 'Cut',
            Font => 'HelveticaBoldItalic',
            FontSize => 7,
            Color => '#666666',
        );
        # set new position
        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -4,
        );
        # table params
        $TableParam{Type} = 'Cut';
        $TableParam{Border} = 0;
        $TableParam{FontSize} = 6;
        $TableParam{BackgroundColor} = '#DDDDDD';
        $TableParam{Padding} = 1;
        $TableParam{PaddingTop} = 3;
        $TableParam{PaddingBottom} = 3;

        # output table
        for ($Page{PageCount}..$Page{MaxPages}) {
            # output table (or a fragment of it)
            %TableParam = $Self->{PDFObject}->Table(
                %TableParam,
            );
            # stop output or output next page
            if ($TableParam{State}) {
                last;
            }
            else {
                $Self->{PDFObject}->PageNew(
                    %Page,
                    FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
                );
                $Page{PageCount}++;
            }
        }
    }
}

sub _PDFOutputTicketFreeText {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(PageData TicketData)) {
        if (!defined ($Param{$_})) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $Output = 0;
    my %Ticket = %{$Param{TicketData}};
    my %Page = %{$Param{PageData}};

    my %TableParam;
    my $Row = 0;
    # generate table
    foreach (1..16) {
        if ($Ticket{"TicketFreeText$_"} ne "") {
            $TableParam{CellData}[$Row][0]{Content} = $Ticket{"TicketFreeKey$_"} . ':';
            $TableParam{CellData}[$Row][0]{Font} = 'HelveticaBold';
            $TableParam{CellData}[$Row][1]{Content} = $Ticket{"TicketFreeText$_"};

            $Row++;
            $Output = 1;
        }
    }
    $TableParam{ColumnData}[0]{Width} = 80;
    $TableParam{ColumnData}[1]{Width} = 431;

    # output ticket freetext
    if ($Output) {
        # set new position
        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -15,
        );
        # output headline
        $Self->{PDFObject}->Text(
            Text => $Self->{LayoutObject}->{LanguageObject}->Get('TicketFreeText'),
            Height => 7,
            Type => 'Cut',
            Font => 'HelveticaBoldItalic',
            FontSize => 7,
            Color => '#666666',
        );
        # set new position
        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -4,
        );

        # table params
        $TableParam{Type} = 'Cut';
        $TableParam{Border} = 0;
        $TableParam{FontSize} = 6;
        $TableParam{BackgroundColor} = '#DDDDDD';
        $TableParam{Padding} = 1;
        $TableParam{PaddingTop} = 3;
        $TableParam{PaddingBottom} = 3;

        # output table
        for ($Page{PageCount}..$Page{MaxPages}) {
            # output table (or a fragment of it)
            %TableParam = $Self->{PDFObject}->Table(
                %TableParam,
            );
            # stop output or output next page
            if ($TableParam{State}) {
                last;
            }
            else {
                $Self->{PDFObject}->PageNew(
                    %Page,
                    FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
                );
                $Page{PageCount}++;
            }
        }
    }
}

sub _PDFOutputTicketFreeTime {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(PageData TicketData)) {
        if (!defined ($Param{$_})) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $Output = 0;
    my %Ticket = %{$Param{TicketData}};
    my %Page = %{$Param{PageData}};

    my %TableParam;
    my $Row = 0;
    # generate table
    foreach (1..2) {
        if ($Ticket{"TicketFreeTime$_"} ne "") {
            $TableParam{CellData}[$Row][0]{Content} = $Ticket{"TicketFreeTimeKey$_"} . ':';
            $TableParam{CellData}[$Row][0]{Font} = 'HelveticaBold';
            $TableParam{CellData}[$Row][1]{Content} = $Ticket{"TicketFreeTime$_"};

            $Row++;
            $Output = 1;
        }
    }
    $TableParam{ColumnData}[0]{Width} = 80;
    $TableParam{ColumnData}[1]{Width} = 431;

    # output ticket freetime
    if ($Output) {
        # set new position
        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -15,
        );
        # output headline
        $Self->{PDFObject}->Text(
            Text => $Self->{LayoutObject}->{LanguageObject}->Get('TicketFreeTime'),
            Height => 7,
            Type => 'Cut',
            Font => 'HelveticaBoldItalic',
            FontSize => 7,
            Color => '#666666',
        );
        # set new position
        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -4,
        );

        # table params
        $TableParam{Type} = 'Cut';
        $TableParam{Border} = 0;
        $TableParam{FontSize} = 6;
        $TableParam{BackgroundColor} = '#DDDDDD';
        $TableParam{Padding} = 1;
        $TableParam{PaddingTop} = 3;
        $TableParam{PaddingBottom} = 3;

        # output table
        for ($Page{PageCount}..$Page{MaxPages}) {
            # output table (or a fragment of it)
            %TableParam = $Self->{PDFObject}->Table(
                %TableParam,
            );
            # stop output or output next page
            if ($TableParam{State}) {
                last;
            }
            else {
                $Self->{PDFObject}->PageNew(
                    %Page,
                    FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
                );
                $Page{PageCount}++;
            }
        }
    }
}

sub _PDFOutputCustomerInfos {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(PageData CustomerData)) {
        if (!defined ($Param{$_})) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my %CustomerData = %{$Param{CustomerData}};
    my %Page = %{$Param{PageData}};
    my %TableParam;
    my $Row = 0;
    my $Map = $CustomerData{Config}{Map};
    foreach my $Field (@{$Map}) {
        if (${$Field}[3] && $CustomerData{${$Field}[0]}) {
            $TableParam{CellData}[$Row][0]{Content} =
                $Self->{LayoutObject}->{LanguageObject}->Get(${$Field}[1]) . ':';
            $TableParam{CellData}[$Row][0]{Font} = 'HelveticaBold';
            $TableParam{CellData}[$Row][1]{Content} = $CustomerData{${$Field}[0]};
            $Row++;
        }
    }
    $TableParam{ColumnData}[0]{Width} = 80;
    $TableParam{ColumnData}[1]{Width} = 431;

    # set new position
    $Self->{PDFObject}->PositionSet(
        Move => 'relativ',
        Y => -15,
    );
    # output headline
    $Self->{PDFObject}->Text(
        Text => $Self->{LayoutObject}->{LanguageObject}->Get('Customer Infos'),
        Height => 7,
        Type => 'Cut',
        Font => 'HelveticaBoldItalic',
        FontSize => 7,
        Color => '#666666',
    );
    # set new position
    $Self->{PDFObject}->PositionSet(
        Move => 'relativ',
        Y => -4,
    );
    # table params
    $TableParam{Type} = 'Cut';
    $TableParam{Border} = 0;
    $TableParam{FontSize} = 6;
    $TableParam{BackgroundColor} = '#DDDDDD';
    $TableParam{Padding} = 1;
    $TableParam{PaddingTop} = 3;
    $TableParam{PaddingBottom} = 3;

    # output table
    for ($Page{PageCount}..$Page{MaxPages}) {
        # output table (or a fragment of it)
        %TableParam = $Self->{PDFObject}->Table(
            %TableParam,
        );
        # stop output or output next page
        if ($TableParam{State}) {
            last;
        }
        else {
            $Self->{PDFObject}->PageNew(
                %Page,
                FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
            );
            $Page{PageCount}++;
        }
    }
}

sub _PDFOutputArticles {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(PageData ArticleData)) {
        if (!defined ($Param{$_})) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my %Page = %{$Param{PageData}};

    my $FirstArticle = 1;
    foreach my $ArticleTmp (@{$Param{ArticleData}}) {
        if ($FirstArticle) {
            $Self->{PDFObject}->PositionSet(
                Move => 'relativ',
                Y => -15,
            );
            # output headline
            $Self->{PDFObject}->Text(
                Text => $Self->{LayoutObject}->{LanguageObject}->Get('Articles'),
                Height => 7,
                Type => 'Cut',
                Font => 'HelveticaBoldItalic',
                FontSize => 7,
                Color => '#666666',
            );
            $Self->{PDFObject}->PositionSet(
                Move => 'relativ',
                Y => 2,
            );
            $FirstArticle = 0;
        }

        my %Article = %{$ArticleTmp};
        # get attacment string
        my %AtmIndex = ();
        if ($Article{Atms}) {
            %AtmIndex = %{$Article{Atms}};
        }
        my $Attachments;
        foreach my $FileID (keys %AtmIndex) {
            my %File = %{$AtmIndex{$FileID}};
            $Attachments .= $File{Filename} . ' (' . $File{Filesize} . ")\n";
        }
        # generate article info table
        my %TableParam1;
        my $Row = 0;
        foreach (qw(From To Cc Subject)) {
            if ($Article{$_}) {
                $TableParam1{CellData}[$Row][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get($_) . ':';
                $TableParam1{CellData}[$Row][0]{Font} = 'HelveticaBold';
                $TableParam1{CellData}[$Row][1]{Content} = $Article{$_};
                $Row++;
            }
        }
        $TableParam1{CellData}[$Row][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Created') . ':';
        $TableParam1{CellData}[$Row][0]{Font} = 'HelveticaBold';
        $TableParam1{CellData}[$Row][1]{Content} =
            $Self->{LayoutObject}->Output(
                Template => '$TimeLong{"$Data{"Created"}"}',
                Data => \%Article,
            );
        $TableParam1{CellData}[$Row][1]{Content} .= ' ' . $Self->{LayoutObject}->{LanguageObject}->Get('by');
        $TableParam1{CellData}[$Row][1]{Content} .= ' ' . $Article{SenderType};
        $Row++;

        foreach (1..3) {
            if ($Article{"FreeText$_"}) {
                $TableParam1{CellData}[$Row][0]{Content} = $Article{"FreeKey$_"} . ':';
                $TableParam1{CellData}[$Row][0]{Font} = 'HelveticaBold';
                $TableParam1{CellData}[$Row][1]{Content} = $Article{"FreeText$_"};
                $Row++;
            }
        }

        $TableParam1{CellData}[$Row][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Type') . ':';
        $TableParam1{CellData}[$Row][0]{Font} = 'HelveticaBold';
        $TableParam1{CellData}[$Row][1]{Content} = $Article{ArticleType};
        $Row++;

        if ($Attachments) {
            $TableParam1{CellData}[$Row][0]{Content} = $Self->{LayoutObject}->{LanguageObject}->Get('Attachment') . ':';
            $TableParam1{CellData}[$Row][0]{Font} = 'HelveticaBold';
            chomp($Attachments);
            $TableParam1{CellData}[$Row][1]{Content} = $Attachments;
        }
        $TableParam1{ColumnData}[0]{Width} = 80;
        $TableParam1{ColumnData}[1]{Width} = 431;

        $Self->{PDFObject}->PositionSet(
            Move => 'relativ',
            Y => -6,
        );

        # table params (article infos)
        $TableParam1{Type} = 'Cut';
        $TableParam1{Border} = 0;
        $TableParam1{FontSize} = 6;
        $TableParam1{BackgroundColor} = '#DDDDDD';
        $TableParam1{Padding} = 1;
        $TableParam1{PaddingTop} = 3;
        $TableParam1{PaddingBottom} = 3;

        # output table (article infos)
        for ($Page{PageCount}..$Page{MaxPages}) {
            # output table (or a fragment of it)
            %TableParam1 = $Self->{PDFObject}->Table(
                %TableParam1,
            );
            # stop output or output next page
            if ($TableParam1{State}) {
                last;
            }
            else {
                $Self->{PDFObject}->PageNew(
                    %Page,
                    FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
                );
                $Page{PageCount}++;
            }
        }

        # table params (article body)
        my %TableParam2;
        $TableParam2{CellData}[0][0]{Content} = $Article{Body} || ' ';
        $TableParam2{Type} = 'Cut';
        $TableParam2{Border} = 0;
        $TableParam2{Font} = 'Courier';
        $TableParam2{FontSize} = 7;
        $TableParam2{BackgroundColor} = '#DDDDDD';
        $TableParam2{Padding} = 4;
        $TableParam2{PaddingTop} = 8;
        $TableParam2{PaddingBottom} = 8;

        # output table (article body)
        for ($Page{PageCount}..$Page{MaxPages}) {
            # output table (or a fragment of it)
            %TableParam2 = $Self->{PDFObject}->Table(
                %TableParam2,
            );
            # stop output or output next page
            if ($TableParam2{State}) {
                last;
            }
            else {
                $Self->{PDFObject}->PageNew(
                    %Page,
                    FooterRight => $Page{PageText} . ' ' . $Page{PageCount},
                );
                $Page{PageCount}++;
            }
        }
    }
}

sub _HTMLMask {
    my $Self = shift;
    my %Param = @_;
    # build article stuff
    my $SelectedArticleID = $Param{ArticleID} || '';
    my @ArticleBox = @{$Param{ArticleBox}};
    # get last customer article
    my $Output = '';
    foreach my $ArticleTmp (@ArticleBox) {
        my %Article = %{$ArticleTmp};
        # get attacment string
        my %AtmIndex = ();
        if ($Article{Atms}) {
            %AtmIndex = %{$Article{Atms}};
        }
        $Param{"Article::ATM"} = '';
        foreach my $FileID (keys %AtmIndex) {
            my %File = %{$AtmIndex{$FileID}};
            $File{Filename} = $Self->{LayoutObject}->Ascii2Html(Text => $File{Filename});
            $Param{"Article::ATM"} .= '<a href="$Env{"Baselink"}Action=AgentTicketAttachment&'.
                "ArticleID=$Article{ArticleID}&FileID=$FileID\" target=\"attachment\" ".
                "onmouseover=\"window.status='\$Text{\"Download\"}: $File{Filename}';".
                ' return true;" onmouseout="window.status=\'\';">'.
                "$File{Filename}</a> $File{Filesize}<br>";
        }
        # check if just a only html email
        if (my $MimeTypeText = $Self->{LayoutObject}->CheckMimeType(%Param, %Article, Action => 'AgentTicketZoom')) {
            $Param{"TextNote"} = $MimeTypeText;
            $Article{"Body"} = '';
        }
        else {
            # html quoting
            $Article{Body} = $Self->{LayoutObject}->Ascii2Html(
                NewLine => $Self->{ConfigObject}->Get('DefaultViewNewLine') || 85,
                Text => $Article{Body},
                VMax => $Self->{ConfigObject}->Get('DefaultViewLines') || 5000,
            );
            # do charset check
            if (my $CharsetText = $Self->{LayoutObject}->CheckCharset(
                Action => 'AgentTicketZoom',
                ContentCharset => $Article{ContentCharset},
                TicketID => $Param{TicketID},
                ArticleID => $Article{ArticleID} )) {
                $Param{"Article::TextNote"} = $CharsetText;
            }
        }
        $Self->{LayoutObject}->Block(
            Name => 'Article',
            Data => {
                %Param,
                %Article
            },
        );
        # do some strips && quoting
        foreach (qw(From To Cc Subject)) {
            if ($Article{$_}) {
                $Self->{LayoutObject}->Block(
                    Name => 'Row',
                    Data => {
                        Key => $_,
                        Value => $Article{$_},
                    },
                );
            }
        }
        # show accounted article time
        if ($Self->{ConfigObject}->Get('Ticket::ZoomTimeDisplay')) {
            my $ArticleTime = $Self->{TicketObject}->ArticleAccountedTimeGet(
                ArticleID => $Article{ArticleID},
            );
            $Self->{LayoutObject}->Block(
                Name => "Row",
                Data => {
                    Key => 'Time',
                    Value => $ArticleTime,
                },
            );
        }
        # show article free text
        foreach (1..3) {
            if ($Article{"FreeText$_"}) {
                $Self->{LayoutObject}->Block(
                    Name => 'ArticleFreeText',
                    Data => {
                        Key => $Article{"FreeKey$_"},
                        Value => $Article{"FreeText$_"},
                    },
                );
            }
        }
    }
    # return output
    return $Self->{LayoutObject}->Output(TemplateFile => 'AgentTicketPrint', Data => {%Param});
}

1;