<script setup>
import { ref, computed, provide } from 'vue';
import { Virtualizer } from 'virtua/vue';
import { useBreakpoints } from '@vueuse/core';
import { differenceInDays, fromUnixTime, isToday, isYesterday } from 'date-fns';
import { useChatListKeyboardEvents } from 'dashboard/composables/chatlist/useChatListKeyboardEvents';
import ConversationItem from './ConversationItem.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import IntersectionObserver from 'dashboard/components/IntersectionObserver.vue';

import wootConstants from 'dashboard/constants/globals';

const props = defineProps({
  conversationList: { type: Array, default: () => [] },
  isLoading: { type: Boolean, default: false },
  showEndOfListMessage: { type: Boolean, default: false },
  label: { type: String, default: '' },
  teamId: { type: [String, Number], default: 0 },
  foldersId: { type: [String, Number], default: 0 },
  conversationType: { type: String, default: '' },
  showAssignee: { type: Boolean, default: false },
  isOnExpandedLayout: { type: Boolean, default: false },
  mailboxRole: { type: String, default: '' },
  sortBy: { type: String, default: 'last_activity_at_desc' },
});

const emit = defineEmits(['loadMore']);

const conversationListRef = ref(null);
const virtualListRef = ref(null);
const isContextMenuOpen = ref(false);

provide('contextMenuElementTarget', virtualListRef);

const breakpoints = useBreakpoints({
  lg: wootConstants.LARGE_SCREEN_BREAKPOINT,
});
const isLgScreen = breakpoints.greaterOrEqual('lg');
const showExpandedCards = computed(
  () => props.isOnExpandedLayout && isLgScreen.value
);

const BUCKET_KEYS = {
  TODAY: 'CHAT_LIST.TIME_BUCKETS.TODAY',
  YESTERDAY: 'CHAT_LIST.TIME_BUCKETS.YESTERDAY',
  THIS_WEEK: 'CHAT_LIST.TIME_BUCKETS.THIS_WEEK',
  THIS_MONTH: 'CHAT_LIST.TIME_BUCKETS.THIS_MONTH',
  OLDER: 'CHAT_LIST.TIME_BUCKETS.OLDER',
};

const chronologicalSortFields = {
  last_activity_at_desc: conversation =>
    conversation.last_activity_at ||
    conversation.timestamp ||
    conversation.created_at,
  created_at_desc: conversation => conversation.created_at,
};

const defaultDisplayTimestamp = conversation =>
  conversation.last_activity_at ||
  conversation.timestamp ||
  conversation.created_at;

const bucketForTimestamp = timestamp => {
  const date = fromUnixTime(timestamp);
  if (isToday(date)) return BUCKET_KEYS.TODAY;
  if (isYesterday(date)) return BUCKET_KEYS.YESTERDAY;

  const ageInDays = differenceInDays(new Date(), date);
  if (ageInDays < 7) return BUCKET_KEYS.THIS_WEEK;
  if (ageInDays < 30) return BUCKET_KEYS.THIS_MONTH;
  return BUCKET_KEYS.OLDER;
};

const conversationRows = computed(() => {
  const sortTimestamp = chronologicalSortFields[props.sortBy];
  let previousBucket = null;

  return props.conversationList.map(conversation => {
    const displayTimestamp = sortTimestamp
      ? sortTimestamp(conversation)
      : defaultDisplayTimestamp(conversation);
    const bucket = sortTimestamp ? bucketForTimestamp(displayTimestamp) : null;
    const bucketHeader = bucket !== previousBucket ? bucket : null;

    previousBucket = bucket;
    return {
      bucketHeader,
      conversation,
      displayTimestamp,
    };
  });
});

useChatListKeyboardEvents(conversationListRef);

const intersectionObserverOptions = computed(() => ({
  root: conversationListRef.value,
  rootMargin: '100px 0px 100px 0px',
}));

const onContextMenuToggle = state => {
  isContextMenuOpen.value = state;
};

const loadMoreConversations = () => {
  emit('loadMore');
};

provide('toggleContextMenu', onContextMenuToggle);

defineExpose({ conversationListRef });
</script>

<template>
  <div
    ref="conversationListRef"
    class="flex-1 min-h-0 overflow-y-auto conversations-list"
    :class="{ '!overflow-hidden': isContextMenuOpen }"
  >
    <Virtualizer
      ref="virtualListRef"
      v-slot="{ item }"
      :data="conversationRows"
      class="[&>div:has(+_div_.active)>*]:!border-n-surface-1 [&>div:has(+_div_.selected)>*]:!border-n-surface-1"
    >
      <div>
        <div
          v-if="item.bucketHeader"
          data-testid="time-bucket-header"
          class="px-3 py-1.5 text-xs font-medium text-n-slate-10 bg-n-background border-b border-n-slate-3"
        >
          {{ $t(item.bucketHeader) }}
        </div>
        <ConversationItem
          :source="item.conversation"
          :display-timestamp="item.displayTimestamp"
          :label="label"
          :team-id="teamId"
          :folders-id="foldersId"
          :conversation-type="conversationType"
          :show-assignee="showAssignee"
          :show-expanded="showExpandedCards"
          :mailbox-role="mailboxRole"
        />
      </div>
    </Virtualizer>
    <div v-if="isLoading" class="flex justify-center my-4">
      <Spinner class="text-n-brand" />
    </div>
    <p v-else-if="showEndOfListMessage" class="p-4 text-center text-n-slate-11">
      {{ $t('CHAT_LIST.EOF') }}
    </p>
    <IntersectionObserver
      v-else
      :options="intersectionObserverOptions"
      @observed="loadMoreConversations"
    />
  </div>
</template>
