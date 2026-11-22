// CMD-77 spike page. DEV ONLY: mounted from Routes.jsx behind import.meta.env.DEV so it never ships.
import React, { useMemo, useState } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import "@astryxdesign/theme-neutral/fonts.css";
import "@astryxdesign/core/reset.css";
import "@astryxdesign/core/astryx.css";
import "@astryxdesign/theme-neutral/theme.css";
import "@fontsource/noto-sans-devanagari/devanagari-400.css";
import "@fontsource/noto-sans-devanagari/devanagari-600.css";
import "./spike.css";

import { Theme } from "@astryxdesign/core/theme";
import { AppShell } from "@astryxdesign/core/AppShell";
import { SideNav, SideNavItem, SideNavSection, SideNavHeading } from "@astryxdesign/core/SideNav";
import { DropdownMenu } from "@astryxdesign/core/DropdownMenu";
import { Layout, LayoutHeader, LayoutContent } from "@astryxdesign/core/Layout";
import { Banner } from "@astryxdesign/core/Banner";
import { Card } from "@astryxdesign/core/Card";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { List, ListItem } from "@astryxdesign/core/List";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Skeleton } from "@astryxdesign/core/Skeleton";
import { useToast } from "@astryxdesign/core/Toast";
import { CommandPalette } from "@astryxdesign/core/CommandPalette";
import { createStaticSource } from "@astryxdesign/core/Typeahead";
import { ChatComposer } from "@astryxdesign/core/Chat";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Selector } from "@astryxdesign/core/Selector";
import { DateInput } from "@astryxdesign/core/DateInput";
import { ProgressBar } from "@astryxdesign/core/ProgressBar";
import { Heading } from "@astryxdesign/core/Heading";
import { Text } from "@astryxdesign/core/Text";
import { VStack, HStack } from "@astryxdesign/core/Stack";

import { clinicTheme } from "theme/clinicTheme";
import BranchManagerDashboard from "pages/branch-manager-dashboard";

const COMMANDS = [
  { id: "cal", label: "Open calendar" },
  { id: "pat", label: "Find a patient" },
  { id: "new", label: "New booking" },
];

function Section({ title, children }) {
  return (
    <Card>
      <VStack gap={3} align="stretch">
        <Heading level={3}>{title}</Heading>
        {children}
      </VStack>
    </Card>
  );
}

function Components() {
  const showToast = useToast();
  const [dialog, setDialog] = useState(false);
  const [palette, setPalette] = useState(false);
  const [text, setText] = useState("");
  const [sel, setSel] = useState("a");
  const [date, setDate] = useState(undefined);
  const source = useMemo(() => createStaticSource(COMMANDS), []);

  return (
    <VStack gap={6} align="stretch">
      <Banner status="warning" title="3 messages need you" description="Banner, yellow" isDismissable />

      <Section title="Buttons">
        <HStack gap={2}>
          <Button label="Primary lg" variant="primary" size="lg" />
          <Button label="Secondary md" size="md" />
          <Button label="Ghost sm" variant="ghost" size="sm" />
          <Button label="Disabled" variant="primary" isDisabled />
          <Button label="Toast" onClick={() => showToast({ body: "Saved", endContent: <Button label="Undo" size="sm" variant="ghost" /> })} />
          <Button label="Dialog" onClick={() => setDialog(true)} />
          <Button label="Palette" onClick={() => setPalette(true)} />
        </HStack>
      </Section>

      <Section title="Badges and who-acted chips (tokens only)">
        <HStack gap={2}>
          <Badge label="Confirmed" variant="success" />
          <Badge label="Needs you" variant="warning" />
          <Badge label="Overdue" variant="error" />
          <Badge label="Booked by Dr. Sharma" variant="neutral" />
          <span className="agent-chip">Follow-up agent drafted</span>
        </HStack>
      </Section>

      <Section title="Nepali text (Noto Sans Devanagari)">
        <Text className="ne">नमस्ते, तपाईंको अपोइन्टमेन्ट भोलि बिहान १० बजे छ।</Text>
        <Text>Mixed line: Bright Smile क्लिनिक, Dr. Sharma — NPR 85,000</Text>
      </Section>

      <Section title="List, EmptyState, Skeleton, ProgressBar">
        <List hasDividers>
          <ListItem label="9:00 Anita Rai" description="Cleaning" endContent={<Badge label="Confirmed" variant="success" />} />
          <ListItem label="10:30 Ram Thapa" description="Root canal" endContent={<Badge label="Waiting" variant="warning" />} />
        </List>
        <EmptyState title="Nothing needs you" description="EmptyState" />
        <Skeleton width={240} height={16} />
        <ProgressBar label="Setup" value={60} hasValueLabel />
      </Section>

      <Section title="Form controls">
        <VStack gap={3} align="stretch">
          <TextInput label="Patient name" value={text} onChange={setText} />
          <Selector label="Chair" value={sel} onChange={setSel} options={[{ value: "a", label: "Chair 1" }, { value: "b", label: "Chair 2" }]} />
          <DateInput label="Date" value={date} onChange={setDate} />
        </VStack>
      </Section>

      <Section title="Ask or tell (ChatComposer)">
        <ChatComposer onSubmit={(v) => showToast({ body: `Sent: ${v}` })} placeholder="Ask or tell…" />
      </Section>

      <Dialog isOpen={dialog} onOpenChange={setDialog}>
        <DialogHeader>Dialog</DialogHeader>
        <Text>Dialog body</Text>
      </Dialog>
      <CommandPalette isOpen={palette} onOpenChange={setPalette} searchSource={source} />
    </VStack>
  );
}

export default function AstryxSpike() {
  const { orgSlug } = useParams();
  const [params] = useSearchParams();
  const legacy = params.get("legacy") === "1";
  return (
    <Theme theme={clinicTheme}>
      <AppShell
        sideNav={
          <SideNav header={<SideNavHeading>ClinicMD</SideNavHeading>}
            topContent={<DropdownMenu button={{ label: "Bright Smile" }} items={[{ label: "Kathmandu" }, { label: "Lalitpur" }]} />}>
            <SideNavSection title="Work">
              <SideNavItem label="Home" icon="home" isSelected href={`/${orgSlug}/__astryx`} />
              <SideNavItem label="Inbox" icon="inbox" endContent={<Badge label="3" variant="error" />} />
              <SideNavItem label="Calendar" icon="calendar" />
            </SideNavSection>
          </SideNav>
        }
      >
        <Layout
          header={<LayoutHeader><HStack gap={2} align="center"><Heading level={1}>{legacy ? "Existing screen" : "Astryx spike"}</Heading><Badge label="12" variant="neutral" /></HStack></LayoutHeader>}
          content={<LayoutContent>{legacy ? <BranchManagerDashboard /> : <Components />}</LayoutContent>}
        />
      </AppShell>
    </Theme>
  );
}
