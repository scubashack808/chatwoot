<script>
const MINUTE_IN_MILLI_SECONDS = 60000;
const HOUR_IN_MILLI_SECONDS = MINUTE_IN_MILLI_SECONDS * 60;
const DAY_IN_MILLI_SECONDS = HOUR_IN_MILLI_SECONDS * 24;

import {
  dynamicTime,
  dateFormat,
  relativeDayTimestamp,
  shortTimestamp,
} from 'shared/helpers/timeHelper';

export default {
  name: 'TimeAgo',
  props: {
    isAutoRefreshEnabled: {
      type: Boolean,
      default: true,
    },
    lastActivityTimestamp: {
      type: [String, Date, Number],
      default: '',
    },
    createdAtTimestamp: {
      type: [String, Date, Number],
      default: '',
    },
    conversationId: {
      type: [String, Number],
      default: '',
    },
    displayTimestamp: {
      type: [String, Date, Number],
      default: '',
    },
    showCalendarTimestamp: {
      type: Boolean,
      default: false,
    },
  },
  data() {
    return {
      lastActivityAtTimeAgo: dynamicTime(this.lastActivityTimestamp),
      createdAtTimeAgo: dynamicTime(this.createdAtTimestamp),
      displayTimestampTimeAgo: dynamicTime(
        this.displayTimestamp || this.lastActivityTimestamp
      ),
      // Held as data rather than computed because it depends on the wall clock,
      // which changes without any prop changing. Seeded in created() so it is
      // correct even when auto refresh is disabled.
      calendarTimestamp: '',
      timer: null,
    };
  },
  computed: {
    lastActivityTime() {
      return shortTimestamp(this.lastActivityAtTimeAgo);
    },
    createdAtTime() {
      return shortTimestamp(this.createdAtTimeAgo);
    },
    effectiveDisplayTimestamp() {
      return this.displayTimestamp || this.lastActivityTimestamp;
    },
    displayTime() {
      return shortTimestamp(this.displayTimestampTimeAgo);
    },
    createdAt() {
      const createdTimeDiff = Date.now() - this.createdAtTimestamp * 1000;
      const isBeforeAMonth = createdTimeDiff > DAY_IN_MILLI_SECONDS * 30;
      return !isBeforeAMonth
        ? `${this.$t('CHAT_LIST.CHAT_TIME_STAMP.CREATED.LATEST')} ${
            this.createdAtTimeAgo
          }`
        : `${this.$t('CHAT_LIST.CHAT_TIME_STAMP.CREATED.OLDEST')} ${dateFormat(
            this.createdAtTimestamp
          )}`;
    },
    lastActivity() {
      const lastActivityTimeDiff =
        Date.now() - this.lastActivityTimestamp * 1000;
      const isNotActive = lastActivityTimeDiff > DAY_IN_MILLI_SECONDS * 30;
      return !isNotActive
        ? `${this.$t('CHAT_LIST.CHAT_TIME_STAMP.LAST_ACTIVITY.ACTIVE')} ${
            this.lastActivityAtTimeAgo
          }`
        : `${this.$t(
            'CHAT_LIST.CHAT_TIME_STAMP.LAST_ACTIVITY.NOT_ACTIVE'
          )} ${dateFormat(this.lastActivityTimestamp)}`;
    },
    tooltipText() {
      return `${this.createdAt}
              ${this.lastActivity}`;
    },
  },
  watch: {
    lastActivityTimestamp() {
      this.lastActivityAtTimeAgo = dynamicTime(this.lastActivityTimestamp);
      if (!this.displayTimestamp) {
        this.displayTimestampTimeAgo = dynamicTime(this.lastActivityTimestamp);
      }
      this.updateCalendarTimestamp();
    },
    createdAtTimestamp() {
      this.createdAtTimeAgo = dynamicTime(this.createdAtTimestamp);
    },
    displayTimestamp() {
      this.displayTimestampTimeAgo = dynamicTime(
        this.effectiveDisplayTimestamp
      );
      this.updateCalendarTimestamp();
    },
    conversationId() {
      // Reset display values and timer when the row is recycled to a different conversation.
      this.lastActivityAtTimeAgo = dynamicTime(this.lastActivityTimestamp);
      this.createdAtTimeAgo = dynamicTime(this.createdAtTimestamp);
      this.displayTimestampTimeAgo = dynamicTime(
        this.effectiveDisplayTimestamp
      );
      this.updateCalendarTimestamp();
      if (this.isAutoRefreshEnabled) {
        clearTimeout(this.timer);
        this.createTimer();
      }
    },
  },
  created() {
    this.updateCalendarTimestamp();
  },
  mounted() {
    if (this.isAutoRefreshEnabled) {
      this.createTimer();
    }
  },
  unmounted() {
    clearTimeout(this.timer);
  },
  methods: {
    updateCalendarTimestamp() {
      // Only the calendar presentation renders this label, and most consumers
      // of this component never ask for it.
      if (!this.showCalendarTimestamp) return;

      this.calendarTimestamp = relativeDayTimestamp(
        this.effectiveDisplayTimestamp,
        this.$t('CHAT_LIST.TIME_BUCKETS.YESTERDAY')
      );
    },
    createTimer() {
      this.timer = setTimeout(() => {
        this.lastActivityAtTimeAgo = dynamicTime(this.lastActivityTimestamp);
        this.createdAtTimeAgo = dynamicTime(this.createdAtTimestamp);
        this.displayTimestampTimeAgo = dynamicTime(
          this.effectiveDisplayTimestamp
        );
        this.updateCalendarTimestamp();
        this.createTimer();
      }, this.refreshTime());
    },
    millisecondsUntilNextDay() {
      const now = new Date();
      const nextDay = new Date(
        now.getFullYear(),
        now.getMonth(),
        now.getDate() + 1,
        0,
        0,
        1
      );
      return nextDay.getTime() - now.getTime();
    },
    refreshTime() {
      const timeDiff = Date.now() - this.effectiveDisplayTimestamp * 1000;
      let interval = MINUTE_IN_MILLI_SECONDS;
      if (timeDiff > DAY_IN_MILLI_SECONDS) {
        interval = DAY_IN_MILLI_SECONDS;
      } else if (timeDiff > HOUR_IN_MILLI_SECONDS) {
        interval = HOUR_IN_MILLI_SECONDS;
      }

      // The calendar label changes at local midnight, so the timer must never
      // sleep past it. Without this a yesterday-dated row keeps a stale label
      // for most of a day.
      if (!this.showCalendarTimestamp) return interval;

      return Math.min(interval, this.millisecondsUntilNextDay());
    },
  },
};
</script>

<template>
  <div
    v-tooltip.top="{
      content: tooltipText,
      delay: { show: 1000, hide: 0 },
    }"
    class="ml-auto leading-4 text-xxs text-n-slate-10 hover:text-n-slate-11"
  >
    <span v-if="showCalendarTimestamp">
      {{ `${calendarTimestamp} • ${displayTime}` }}
    </span>
    <span v-else>{{ `${createdAtTime} • ${lastActivityTime}` }}</span>
  </div>
</template>
